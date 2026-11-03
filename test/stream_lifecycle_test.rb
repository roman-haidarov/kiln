require 'kiln'
require 'socket'
require 'stringio'
require 'test/support'

module ResetClient
  ffi_lib 'pthread'
  ffi_func :setsockopt, %i[int int int str int], :int
end

def check(label, result)
  raise "FAIL #{label}" unless result

  puts "ok   #{label}"
end

def lifecycle_request(port, method = 'GET', path = '/')
  exchange(port, "#{method} #{path} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", 2)
end

%i[event base].each do |backend|
  released = Queue.new
  entered = Queue.new
  handler = lambda do |ctx|
    if ctx.req.path == '/timeout'
      ctx.res.stream(release: -> { released << true }) { |out| out.write('unused') }
      entered << true
      Kernel.sleep 2
    else
      ctx.res.text('ok')
    end
  end
  options = {backend: backend, host: '127.0.0.1', port: 0, request_timeout: 0.05}
  backend == :event ? options[:handlers] = 2 : options[:kill_grace] = 0.01
  server = Kiln::Server.new(handler, **options)
  server.start
  begin
    raw = lifecycle_request(server.port, 'GET', '/timeout')
    wait_for { released.size == 1 }
    check "#{backend}: forced timeout releases an unstarted stream",
          raw.start_with?('HTTP/1.1 504 ') && entered.size == 1 && server.killed == 1
    check "#{backend}: the replacement handler keeps serving", lifecycle_request(server.port).end_with?('ok')
  ensure
    server.shutdown(grace: 0.1)
  end
  check "#{backend}: shutdown does not release a timed-out response twice", released.size == 1
end

released = Queue.new
upload = Kiln::Server.new(lambda { |ctx|
  ctx.res.stream(release: -> { released << true }) { |out| out.write('unused') }
  Kernel.sleep 2
}, host: '127.0.0.1', port: 0, handlers: 0, buffer_body: 1, request_timeout: 0.05)
upload.start
begin
  sock = TCPSocket.new('127.0.0.1', upload.port)
  sock.write("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 4096\r\nConnection: close\r\n\r\nabc")
  raw = read_until_closed(sock, 2)
  wait_for { released.size == 1 }
  check 'forced upload timeout releases an unstarted stream', raw.start_with?('HTTP/1.1 504 ')
ensure
  sock&.close
  upload.shutdown(grace: 0.1)
end
check 'upload shutdown keeps release exactly once', released.size == 1

%i[event base].each do |backend|
  released = Queue.new
  logger = Kiln::Observability::Log.new(StringIO.new)
  handler = lambda do |ctx|
    if ctx.req.path == '/bad'
      ctx.res.stream(release: lambda { released << true; raise 'cleanup failed' }) { |out| out.write('unused') }
    else
      ctx.res.text('ok')
    end
  end
  server = Kiln::Server.new(handler, backend: backend, host: '127.0.0.1', port: 0, log: logger)
  server.start
  begin
    raw = lifecycle_request(server.port, 'HEAD', '/bad')
    health = lifecycle_request(server.port)
    check "#{backend}: a release exception cannot stop the server",
          raw.start_with?('HTTP/1.1 200 ') && health.end_with?('ok') && released.size == 1
  ensure
    server.shutdown(grace: 0.1)
  end
end

started = Queue.new
released = Queue.new
gate = Queue.new
active = 0
peak = 0
lock = Mutex.new
handler = lambda do |ctx|
  ctx.res.stream(release: -> { released << true }) do |out|
    lock.synchronize { active += 1; peak = [peak, active].max }
    begin
      out.write('x')
      out.flush
      started << true
      gate.pop
    ensure
      lock.synchronize { active -= 1 }
    end
  end
end
server = Kiln::Server.new(handler, host: '127.0.0.1', port: 0, handlers: 1, max_streams: 2)
server.start
begin
  6.times do |index|
    sock = TCPSocket.new('127.0.0.1', server.port)
    sock.write("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
    head, = read_head(sock, 2)
    raise 'stream rejected during slot reuse' unless head.start_with?('HTTP/1.1 200 ')
    raise 'stream body did not start' unless started.pop(timeout: 1)
    raise 'RST setup failed' unless ResetClient.setsockopt(sock.fileno, Socket::SOL_SOCKET, Socket::SO_LINGER,
                                                         [1, 0].pack('ii'), 8).zero?

    sock.close
    wait_for { server.connections.zero? }
    wait_for { released.size >= index } if index.positive?
  end
ensure
  server.shutdown(grace: 0)
end
check 'slot reuse keeps producer count within max_streams', lock.synchronize { peak <= 2 && active.zero? }
check 'shutdown releases every generation without application help', released.size == 6
6.times { gate << true }
Kernel.sleep 0.03
check 'late producer notifications cannot release twice', released.size == 6

started = Queue.new
released = Queue.new
gate = Queue.new
server = Kiln::Server.new(lambda { |ctx|
  ctx.res.stream(release: -> { released << true }) do |out|
    out.write('ok')
    out.flush
    if ctx.req.path == '/wait'
      started << true
      gate.pop
    end
  end
}, host: '127.0.0.1', port: 0, max_streams: 1)
server.start
begin
  sock = TCPSocket.new('127.0.0.1', server.port)
  sock.write("GET /wait HTTP/1.1\r\nHost: x\r\n\r\n")
  read_head(sock, 2)
  raise 'idle producer did not start' unless started.pop(timeout: 1)
  raise 'RST setup failed' unless ResetClient.setsockopt(sock.fileno, Socket::SOL_SOCKET, Socket::SO_LINGER,
                                                       [1, 0].pack('ii'), 8).zero?

  sock.close
  deadline = Kiln::Runtime.now + 3
  until released.size == 1 && server.in_flight.zero?
    raise 'disconnected producer did not stop' if Kiln::Runtime.now >= deadline

    Kernel.sleep 0.01
  end
  check 'disconnect cancels an idle producer without slot reuse', released.size == 1
  check 'disconnect returns the last stream reservation', lifecycle_request(server.port).start_with?('HTTP/1.1 200 ')
ensure
  gate << true
  sock&.close unless sock&.closed?
  server.shutdown(grace: 0.1)
end

%i[event base].each do |backend|
  %i[plain gzip].each do |encoding|
    released = Queue.new
    ran = Queue.new
    handler = ->(ctx) { ctx.res.stream(type: 'text/plain', release: -> { released << true }) { |out| ran << true; out.write('x' * 1024) } }
    handler = Kiln::Middleware::Compress.new(handler, min_size: 0) if encoding == :gzip
    server = Kiln::Server.new(handler, backend: backend, host: '127.0.0.1', port: 0)
    server.start
    begin
      %w[GET HEAD].each do |verb|
        raw = exchange(server.port, "#{verb} / HTTP/1.1\r\nHost: x\r\nAccept-Encoding: gzip\r\nConnection: close\r\n\r\n", 2)
        raise 'release matrix status' unless raw.start_with?('HTTP/1.1 200 ')
      end
      wait_for { released.size == 2 }
      check "#{backend}: #{encoding} GET and HEAD release once", ran.size == 1
    ensure
      server.shutdown(grace: 0.1)
    end
  end
end

released = Queue.new
response = Kiln::HTTP::Response.new
response.stream(release: -> { released << true }) { |_out| nil }
Array.new(16) { Thread.new { response.release_stream } }.each(&:join)
check 'concurrent terminal paths consume release once', released.size == 1

released = Queue.new
response = Kiln::HTTP::Response.new
response.stream(release: -> { released << true }) { |_out| nil }
threads = [Thread.new { response.hijack { |_tunnel| nil } }, Thread.new { response.release_stream }]
threads.each(&:join)
response.release_stream
check 'upgrading and cancellation share one cleanup owner', released.size == 1 && response.tunnel? && !response.streaming?

gate = Queue.new
router = Kiln::Routing::Router.new
router.get('/slow', lambda { |ctx|
  Kernel.sleep 0.4
  ctx.res.text('late')
})
router.get('/stream', lambda { |ctx|
  ctx.res.stream do |out|
    out.write('a')
    out.flush
    gate.pop(timeout: 3)
    out.write('b')
  end
})
router.seal!
server = Kiln::Server.new(router, host: '127.0.0.1', port: 0, handlers: 2)
server.start
begin
  old = TCPSocket.new('127.0.0.1', server.port)
  old.write("GET /slow HTTP/1.1\r\nHost: x\r\n\r\n")
  Kernel.sleep 0.05
  raise 'RST setup failed' unless ResetClient.setsockopt(old.fileno, Socket::SOL_SOCKET, Socket::SO_LINGER,
                                                       [1, 0].pack('ii'), 8).zero?

  old.close
  Kernel.sleep 0.05
  fresh = TCPSocket.new('127.0.0.1', server.port)
  fresh.write("GET /stream HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
  Kernel.sleep 0.6
  gate << true
  body = read_until_closed(fresh, 2)
  check 'a late response of a reset connection leaves a newer stream on its slot alone',
        body.end_with?("1\r\nb\r\n0\r\n\r\n")
ensure
  server.shutdown(grace: 0.1)
end
