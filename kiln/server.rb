module Kiln
  class Server
    MAX_HEADER = 16 * 1024

    def initialize(handler, app, log:, port:, max_conns: 10_000, read_timeout: 5.0, request_timeout: 2.0)
      @handler, @app, @log, @port = handler, app, log, port
      @read_timeout, @request_timeout = read_timeout, request_timeout
      @slots = SizedQueue.new(max_conns)
      max_conns.times { @slots << true }
      @lock = Mutex.new
      @conns = {}          # Thread => true
      @in_flight = 0
      @seq = 0
      @draining = false
    end

    def start
      @listener = TCPServer.new("0.0.0.0", @port)
      @acceptor = Thread.new { accept_loop }
    end

    # Graceful: перестать принимать, дождаться запросов в работе, убить простаивающие.
    def shutdown(grace: 5.0)
      @draining = true
      @acceptor.kill
      @listener.close
      deadline = Kiln.now + grace
      sleep 0.01 while in_flight > 0 && Kiln.now < deadline
      left = in_flight
      threads = @lock.synchronize { @conns.keys }
      threads.each(&:kill)
      left
    end

    def in_flight = @lock.synchronize { @in_flight }
    def connections = @lock.synchronize { @conns.size }

    private

    def accept_loop
      loop do
        sock = @listener.accept
        unless @slots.pop(timeout: 0)
          sock.write("HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
          sock.close
          next
        end
        th = Thread.new(sock) { |s| connection(s) }
        @lock.synchronize { @conns[th] = true }
      end
    end

    def connection(sock)
      buf = +""
      loop do
        req = read_request(sock, buf)
        break unless req
        keep = serve(req, sock)
        break unless keep && !@draining
      end
    rescue IOError, SystemCallError
    ensure
      sock.close
      @lock.synchronize { @conns.delete(Thread.current) }
      @slots << true
    end

    def serve(req, sock)
      @lock.synchronize { @in_flight += 1 }
      begin
        id = @lock.synchronize { @seq += 1 }.to_s(36)
        ctx = Context.new(req, Response.new, @app, id, Kiln.now + @request_timeout)
        @handler.call(ctx)
        keep = req.header("connection") != "close"
        sock.write(ctx.res.to_wire(keep))
        Thread.current[:request_id] = nil
        keep
      ensure
        @lock.synchronize { @in_flight -= 1 }
      end
    end

    def read_request(sock, buf)
      until (i = buf.index("\r\n\r\n"))
        return nil if buf.bytesize > MAX_HEADER
        return nil unless fill(sock, buf)
      end
      head = buf[0, i]
      buf.replace(buf[(i + 4)..] || "")
      lines = head.split("\r\n")
      verb, target, _v = lines.shift.to_s.split(" ")
      headers = {}
      lines.each do |l|
        k, v = l.split(": ", 2)
        headers[k.downcase] = v.to_s if k
      end
      len = headers["content-length"].to_i
      while buf.bytesize < len
        return nil unless fill(sock, buf)
      end
      body = buf.byteslice(0, len)
      buf.replace(buf.byteslice(len, buf.bytesize - len) || "")
      Request.new(verb.to_s, target.to_s, headers, body)
    end

    def fill(sock, buf)
      ready, = IO.select([sock], nil, nil, @read_timeout)
      return false unless ready
      buf << sock.readpartial(16_384)
      true
    rescue EOFError
      false
    end
  end
end
