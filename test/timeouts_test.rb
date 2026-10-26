require 'kiln'
require 'socket'
require 'stringio'
require 'test/support'

def check(label, passed)
  raise "FAIL #{label}" unless passed

  puts "ok   #{label}"
end

log = Kiln::Observability::Log.new(StringIO.new)
router = Kiln::Routing::Router.new
router.get('/', ->(ctx) { ctx.res.text('ok') })
router.post('/echo', ->(ctx) { ctx.res.text("len=#{ctx.req.body.bytesize}") })
router.post('/ignore', ->(ctx) { ctx.res.text('ignored') })
router.seal!
big = 'z' * (2 << 20)

%i[event base].each do |backend|
  server = Kiln::Server.new(router, log: log, backend: backend, host: '127.0.0.1', port: 0,
                                         header_timeout: 0.1, keep_alive_timeout: 0.4, read_timeout: 0.3,
                                         request_timeout: 1.0,
                                         client_disconnect_timeout: 0.3, buffer_body: 1024)
  server.start
  port = server.port

  slow = TCPSocket.new('127.0.0.1', port)
  started = Kiln::Runtime.now
  slow.write("GET / HTTP/1.1\r\nHost: x\r\n")
  reply = read_until_closed(slow, 1)
  elapsed = Kiln::Runtime.now - started
  check "#{backend}: a head that never ends gets 408 after header_timeout",
        reply.start_with?('HTTP/1.1 408 ') && elapsed >= 0.08 && elapsed < 1.0

  silent = TCPSocket.new('127.0.0.1', port)
  started = Kiln::Runtime.now
  quiet = closed_within?(silent, 1)
  elapsed = Kiln::Runtime.now - started
  silent.close
  check "#{backend}: a connection that sends nothing is closed after header_timeout",
        quiet && elapsed >= 0.08 && elapsed < 1.0

  idle = TCPSocket.new('127.0.0.1', port)
  idle.write("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
  head, = read_head(idle)
  started = Kiln::Runtime.now
  gone = closed_within?(idle, 1)
  elapsed = Kiln::Runtime.now - started
  idle.close
  check "#{backend}: an idle keep-alive connection is closed after keep_alive_timeout",
        head.start_with?('HTTP/1.1 200 ') && !head.include?('Connection: close') && gone && elapsed >= 0.3 &&
        elapsed < 1.0

  pause = TCPSocket.new('127.0.0.1', port)
  pause.write("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
  read_head(pause)
  Kernel.sleep 0.1
  pause.write("GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
  second = read_until_closed(pause, 0.7)
  pause.close
  check "#{backend}: a request within keep_alive_timeout reuses the connection", second.start_with?('HTTP/1.1 200 ')

  stalled = TCPSocket.new('127.0.0.1', port)
  stalled.write("POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 4096\r\n\r\nabc")
  started = Kiln::Runtime.now
  stalled_reply = read_until_closed(stalled, 1.5)
  elapsed = Kiln::Runtime.now - started
  stalled.close
  check "#{backend}: a streamed body that stalls gets 408 after read_timeout",
        stalled_reply.start_with?('HTTP/1.1 408 ') && elapsed >= 0.25 && elapsed < 1.5

  pushing = TCPSocket.new('127.0.0.1', port)
  pushing.write("POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: #{big.bytesize}\r\n\r\n")
  writer = Thread.new do
    sent = 0
    begin
      while sent < big.bytesize
        sent += pushing.write(big.byteslice(sent, 65_536))
      end
    rescue IOError, SystemCallError
      nil
    end
    sent
  end
  refused = collect_until(pushing, 1) { |buf| buf.include?('payload too large') }
  writer.join(1)
  pushing.close
  check "#{backend}: a 413 reaches a client that is still sending its body",
        refused.start_with?('HTTP/1.1 413 ') && refused.include?('Connection: close')

  ignore = TCPSocket.new('127.0.0.1', port)
  ignore.write("POST /ignore HTTP/1.1\r\nHost: x\r\nContent-Length: 2000\r\n\r\n#{'q' * 2000}" \
               "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
  both = read_until_closed(ignore, 0.7)
  ignore.close
  check "#{backend}: an unread small body is discarded and the connection kept",
        both.scan('HTTP/1.1 200 ').size == 2 && both.include?('ignored')
  server.shutdown(grace: 0.5)

  single = Kiln::Server.new(router, log: log, backend: backend, host: '127.0.0.1', port: 0,
                                         keep_alive_timeout: 0)
  single.start
  closing = exchange(single.port, "GET / HTTP/1.1\r\nHost: x\r\n\r\nGET / HTTP/1.1\r\nHost: x\r\n\r\n")
  check "#{backend}: keep_alive_timeout 0 closes after every response",
        closing.scan('HTTP/1.1 200 ').size == 1 && closing.include?('Connection: close')
  single.shutdown(grace: 0.5)
end

short = Kiln::Server.new(router, log: log, backend: :event, host: '127.0.0.1', port: 0,
                                      header_timeout: 0.04, read_timeout: 1.0, request_timeout: 1.0)
short.start
partial = TCPSocket.new('127.0.0.1', short.port)
started = Kiln::Runtime.now
partial.write("GET / HTTP/1.1\r\nHost: x\r\n")
reply = read_until_closed(partial, 1)
elapsed = Kiln::Runtime.now - started
partial.close
check 'event header timeout wakes the pump before its handler wait expires',
      reply.start_with?('HTTP/1.1 408 ') && elapsed >= 0.03 && elapsed < 0.2
short.shutdown(grace: 0.5)

log.close
