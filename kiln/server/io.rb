module Kiln
  class Server
    private

    def linger(sock)
      sock.shutdown(Socket::SHUT_WR)
      limit = Kiln.now + LINGER
      drained = 0
      while drained < LINGER_BYTES
        chunk = sock.read_nonblock(16_384, exception: false)
        if chunk == :wait_readable
          left = limit - Kiln.now
          break if left <= 0
          ready, = IO.select([sock], nil, nil, left)
          break unless ready
          next
        end
        break if chunk.nil?
        drained += chunk.bytesize
      end
    rescue EOFError, IOError, SystemCallError
      nil
    end

    def log_accept_error(error, delay)
      @log.error("accept error: #{error.class}: #{error.message}; retrying in #{delay}s")
    rescue Exception
      nil
    end

    def write_all(sock, data, deadline)
      fd = sock.fileno
      off = 0
      total = data.bytesize
      while off < total
        return false if Kiln.now >= deadline
        n = HttpNative.kiln_send(fd, data, total, off, total - off)
        if n == -1
          left = deadline - Kiln.now
          return false if left <= 0
          _, w, = IO.select(nil, [sock], nil, left)
          return false unless w
        elsif n < 0
          return false
        else
          off += n
        end
      end
      true
    rescue IOError, SystemCallError
      false
    end

    def fixed_headers
      h = Headers.new
      h["Content-Type"] = "text/plain"
      h
    end

    def write_fixed(sock, status, message, deadline, version = "1.1")
      wire = Response.build_wire(status, fixed_headers, "#{message}\n", false, version: version)
      write_all(sock, wire, deadline)
    end

    def close_quietly(sock)
      return unless sock && !sock.closed?
      sock.close
    rescue IOError, SystemCallError
      nil
    end

    def quiet_join(thread)
      limit = Kiln.now + 0.5
      Kernel.sleep 0.01 while thread.alive? && Kiln.now < limit
      !thread.alive?
    rescue Exception
      nil
    end

    def flush_outbox(sock, box, deadline)
      return true if box.empty?
      sent = write_all(sock, box.data, deadline)
      box.reset
      sent
    end

    def safe_io
      yield
    rescue IOError, SystemCallError
      nil
    end
  end
end
