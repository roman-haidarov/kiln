require 'kiln'
require 'socket'
require 'stringio'
require 'test/support'

def check(label, passed)
  raise "FAIL #{label}" unless passed

  puts "ok   #{label}"
end

BIG = ('x' * (1024 * 1024)).freeze
BIG_CALLS = Queue.new
SLOW_STARTED = Queue.new
AFTER_CALLS = Queue.new
PIPELINED = 64

log = Kiln::Observability::Log.new(StringIO.new)
router = Kiln::Routing::Router.new
                              .get('/big', lambda { |ctx|
                                             BIG_CALLS << 1
                                             ctx.res.text(BIG)
                                           })
                              .get('/slow', lambda { |ctx|
                                              SLOW_STARTED << 1
                                              Kernel.sleep 0.15
                                              ctx.res.text('slow')
                                            })
                              .get('/after', lambda { |ctx|
                                               AFTER_CALLS << 1
                                               ctx.res.text('after')
                                             })
                              .seal!

def big_pipeline
  data = (+'').b
  i = 1
  while i <= PIPELINED
    data << "GET /big HTTP/1.1\r\nHost: x\r\n#{"Connection: close\r\n" if i == PIPELINED}\r\n"
    i += 1
  end
  data
end

def wait_calls(limit)
  last = -1
  while Kiln::Runtime.now < limit
    now = BIG_CALLS.size
    break if now == last

    last = now
    Kernel.sleep 0.3
  end
  BIG_CALLS.size
end

def drain_bytes(sock, seconds)
  total = 0
  limit = Kiln::Runtime.now + seconds
  while Kiln::Runtime.now < limit
    ready, = IO.select([sock], nil, nil, limit - Kiln::Runtime.now)
    break unless ready

    chunk = begin
      sock.read_nonblock(1_048_576, exception: false)
    rescue IOError, SystemCallError
      nil
    end
    next if chunk == :wait_readable
    break unless chunk.is_a?(String)

    total += chunk.bytesize
  end
  total
end

def unread_backlog(server)
  BIG_CALLS.clear
  sock = TCPSocket.new('127.0.0.1', server.port)
  sock.write(big_pipeline)
  started = wait_calls(Kiln::Runtime.now + 5)
  total = drain_bytes(sock, 60)
  sock.close
  [started, total]
end

def ordered_error(port, bad)
  AFTER_CALLS.clear
  SLOW_STARTED.clear
  sock = TCPSocket.new('127.0.0.1', port)
  sock.write("GET /slow HTTP/1.1\r\nHost: x\r\n\r\n#{bad}GET /after HTTP/1.1\r\nHost: x\r\n\r\n")
  reply = read_until_closed(sock, 10)
  sock.close
  first = reply.index('HTTP/1.1 200 ')
  error = reply.index(bad.start_with?('CONNECT') ? 'HTTP/1.1 501 ' : 'HTTP/1.1 400 ')
  first && error && first < error && reply.include?('slow') && !reply.include?('after') && AFTER_CALLS.empty?
end

[2, 0].each do |handlers|
  server = Kiln::Server::Event.new(router, log: log, port: 0, handlers: handlers, write_timeout: 60)
  server.start
  started, total = unread_backlog(server)
  check "handlers #{handlers}: an unread pipeline of 1 MiB replies runs a bounded number of handlers",
        started < PIPELINED / 2
  check "handlers #{handlers}: every pipelined reply arrives once the client reads",
        total >= PIPELINED * BIG.bytesize && total < PIPELINED * (BIG.bytesize + 512)
  server.shutdown(grace: 1)
end

ordered = Kiln::Server::Event.new(router, log: log, port: 0, handlers: 2)
ordered.start
check 'a request without Host is answered after the earlier response',
      ordered_error(ordered.port, "GET /x HTTP/1.1\r\n\r\n")
check 'CONNECT is answered after the earlier response',
      ordered_error(ordered.port, "CONNECT x:443 HTTP/1.1\r\nHost: x\r\n\r\n")
check 'a bad target is answered after the earlier response',
      ordered_error(ordered.port, "GET x HTTP/1.1\r\nHost: x\r\n\r\n")
ordered.shutdown(grace: 1)
