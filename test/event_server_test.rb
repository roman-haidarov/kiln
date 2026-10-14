require 'kiln'
require 'socket'
require 'stringio'
require 'test/support'

def check(label, passed)
  raise "FAIL #{label}" unless passed

  puts "ok   #{label}"
end

CALLS = Queue.new
BIG_BODY = ('0123456789' * 200_000).freeze
PAUSED = Queue.new
SHUTDOWN_CALLS = Queue.new
HANG_STARTED = Queue.new
log = Kiln::Log.new(StringIO.new)
router = Kiln::Router.new
                     .get('/', ->(ctx) { ctx.res.text("Hello, World!\n") })
                     .post('/echo', ->(ctx) { ctx.res.text("len=#{ctx.req.body.bytesize}") })
                     .get('/sleep', lambda { |ctx|
                                      ctx.sleep(0.3)
                                      ctx.res.text("slept\n")
                                    })
                     .get('/boom', ->(_ctx) { raise 'boom' })
                     .get('/count', lambda { |ctx|
                                      CALLS << 1
                                      ctx.res.text("counted\n")
                                    })
                     .get('/shutdown-pipe', lambda { |ctx|
                                              SHUTDOWN_CALLS << 1
                                              ctx.sleep(0.05)
                                              ctx.res.text("piped\n")
                                            })
                     .get('/pause', lambda { |ctx|
                                      PAUSED << 1
                                      ctx.sleep(0.3)
                                      ctx.res.text("paused\n")
                                    })
                     .get('/utf', ->(ctx) { ctx.res.text('привет') })
                     .get('/big', ->(ctx) { ctx.res.text(BIG_BODY) })
                     .get('/deadline', ->(ctx) { ctx.res.text(Kiln.deadline.positive? ? 'set' : 'unset') })
                     .get('/late', lambda { |ctx|
                                     Kernel.sleep 0.3
                                     Kiln.check!
                                     ctx.res.text('never')
                                   })
                     .get('/hang', lambda { |ctx|
                                     HANG_STARTED << 1
                                     Kernel.sleep 1.5
                                     ctx.res.text("late\n")
                                   })
                     .seal!

inline = Kiln::Server::Event.new(router, nil, log: log, port: 0, request_timeout: 0.2)
inline.start
ip = inline.port
o = exchange(ip, "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
check 'inline: 200 with body and close',
      o.start_with?('HTTP/1.1 200 ') && o.end_with?("Hello, World!\n") && o.include?('Connection: close')
batch = (+'').b
15.times { batch << "GET / HTTP/1.1\r\nHost: x\r\n\r\n" }
batch << "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
check 'inline: 16 pipelined requests -> 16 responses', exchange(ip, batch).scan('HTTP/1.1 200 ').size == 16
o = exchange(ip, "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello")
check 'inline: Content-Length body reaches the handler', o.end_with?('len=5')
o = exchange(ip, "GET /utf HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
check 'inline: non-ASCII body is sent byte-for-byte',
      o.b.end_with?("\r\n\r\n".b + 'привет'.b) && o.include?('Content-Length: 12')
o = exchange(ip, "HEAD /utf HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
check 'inline: HEAD keeps Content-Length and sends no body', o.include?('Content-Length: 12') && o.end_with?("\r\n\r\n")
big_client = TCPSocket.new('127.0.0.1', ip)
big_client.write("GET /big HTTP/1.1\r\nHost: x\r\n\r\nGET /big HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
Kernel.sleep 0.3
o = read_until_closed(big_client, 5)
big_client.close
check 'inline: two large pipelined responses arrive whole and in order',
      o.scan('HTTP/1.1 200 ').size == 2 && o.scan(BIG_BODY.b).size == 2 && o.end_with?(BIG_BODY.b)
check 'inline: malformed request -> 400', exchange(ip, "GARBAGE\r\n\r\n").start_with?('HTTP/1.1 400 ')
check 'inline: missing Host on HTTP/1.1 -> 400',
      exchange(ip, "GET / HTTP/1.1\r\nConnection: close\r\n\r\n").start_with?('HTTP/1.1 400 ')
check 'inline: Transfer-Encoding -> 501',
      exchange(ip,
               "POST /echo HTTP/1.1\r\nHost: x\r\n" \
               "Transfer-Encoding: chunked\r\n\r\n0\r\n\r\n").start_with?('HTTP/1.1 501 ')
check 'inline: handler error -> 500',
      exchange(ip, "GET /boom HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n").start_with?('HTTP/1.1 500 ')
check 'inline: unknown route -> 404',
      exchange(ip, "GET /none HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n").start_with?('HTTP/1.1 404 ')
o = exchange(ip, "GET /count HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\nGET /count HTTP/1.1\r\nHost: x\r\n\r\n")
check 'inline: request after Connection: close is not executed', o.scan('HTTP/1.1 200 ').size == 1 && CALLS.size == 1
CALLS.clear
o = exchange(ip, "GET /count HTTP/1.0\r\n\r\nGET /count HTTP/1.0\r\n\r\n")
check 'inline: HTTP/1.0 without keep-alive stops after one request', o.scan(' 200 ').size == 1 && CALLS.size == 1
check 'inline: request deadline is visible to Kiln.deadline',
      exchange(ip, "GET /deadline HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n").end_with?('set')
check 'inline: Kiln.check! after the deadline -> 504',
      exchange(ip, "GET /late HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n").start_with?('HTTP/1.1 504 ')
check 'inline: unsupported Expect -> 417',
      exchange(ip,
               "POST /echo HTTP/1.1\r\nHost: x\r\nExpect: magic\r\n" \
               "Content-Length: 2\r\n\r\nhi").start_with?('HTTP/1.1 417 ')
cont = TCPSocket.new('127.0.0.1', ip)
cont.write("GET / HTTP/1.1\r\nHost: x\r\n\r\n" \
           "POST /echo HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\n" \
           "Content-Length: 5\r\nConnection: close\r\n\r\n")
seen = collect_until(cont, 2) { |buf| buf.include?('100 Continue') }
first_ok = seen.index('HTTP/1.1 200 ')
continue_at = seen.index('HTTP/1.1 100 Continue')
cont.write('hello')
rest = collect_until(cont, 2) { |buf| buf.include?('len=5') }
cont.close
check 'inline: 100 Continue after earlier responses, then the body is served',
      first_ok.zero? && continue_at && continue_at > first_ok && rest.include?('len=5')
pipe_client = Thread.new do
  data = (1..3).map do |i|
    "GET /shutdown-pipe HTTP/1.1\r\nHost: x\r\n#{"Connection: close\r\n" if i == 3}\r\n"
  end.join
  exchange(ip, data, 3.0)
end
SHUTDOWN_CALLS.pop
pipe_shutdown_left = inline.shutdown(grace: 1)
pipe_response = pipe_client.value
check 'inline: shutdown finishes every request already parsed from a pipeline',
      pipe_shutdown_left.zero? && SHUTDOWN_CALLS.size == 2 && pipe_response.scan('HTTP/1.1 200 ').size == 3
check 'inline: shutdown releases connections', inline.connections.zero?
hung = Kiln::Server::Event.new(router, nil, log: log, port: 0)
hung.start
hung_data = (1..3).map { |i| "GET /hang HTTP/1.1\r\nHost: x\r\n#{"Connection: close\r\n" if i == 3}\r\n" }.join
hung_client = Thread.new { exchange(hung.port, hung_data, 3.0) }
HANG_STARTED.pop
hung_left = hung.shutdown(grace: 0.2)
hung_client.join
check 'inline: unfinished count includes queued requests when the handler is stopped', hung_left == 3

last = Kiln::Server::Event.new(router, nil, log: log, port: 0)
last.start
last_out = Queue.new
last_client = Thread.new { last_out << exchange(last.port, "GET /pause HTTP/1.1\r\nHost: x\r\n\r\n", 3.0) }
PAUSED.pop
last.shutdown(grace: 2)
last_client.join
paused = last_out.pop
check 'inline: the response finished during shutdown says Connection: close',
      paused.start_with?('HTTP/1.1 200 ') && paused.include?('Connection: close')

ipv6 = begin
  TCPServer.new('::1', 0).close
  true
rescue SystemCallError
  false
end
v6_served = true
if ipv6
  v6 = Kiln::Server::Event.new(router, nil, log: log, host: '::1', port: 0)
  v6.start
  v6_client = TCPSocket.new('::1', v6.port)
  v6_client.write("GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
  v6_served = read_until_closed(v6_client, 2).end_with?("Hello, World!\n")
  v6_client.close
  v6.shutdown(grace: 0)
end
check 'inline: listens on ::1 when the host has IPv6', v6_served

more = Kiln::Server::Event.new(router, nil, log: log, port: 0)
more.start
mp = more.port
half = TCPSocket.new('127.0.0.1', mp)
half.write("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
half.shutdown(Socket::SHUT_WR)
half_body = read_until_closed(half, 2)
half.close
check 'inline: half-close after a complete request still gets a response',
      half_body.start_with?('HTTP/1.1 200 ') && half_body.end_with?("Hello, World!\n")
ordered = exchange(mp, "GET / HTTP/1.1\r\nHost: x\r\n\r\nGARBAGE\r\n\r\n")
ok_at = ordered.index('HTTP/1.1 200 ')
bad_at = ordered.index('HTTP/1.1 400 ')
check 'inline: a good request is answered before the following 400',
      ok_at && bad_at && ok_at < bad_at && ordered.include?("Hello, World!\n")
wide = (+'').b
16.times { wide << "GET / HTTP/1.1\r\nHost: x\r\n\r\n" }
wide << "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
check 'inline: 17 pipelined requests -> 17 responses', exchange(mp, wide, 3).scan('HTTP/1.1 200 ').size == 17
more.shutdown(grace: 0.5)

slow = Kiln::Server::Event.new(->(ctx) { ctx.res.text('z' * (8 << 20)) }, nil,
                               log: log, port: 0, write_timeout: 0.2)
slow.start
slow_sock = TCPSocket.new('127.0.0.1', slow.port)
slow_sock.write("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
wait_for { slow.connections.positive? }
slow_closed = false
slow_limit = Kiln.now + 2
while Kiln.now < slow_limit
  if slow.connections.zero?
    slow_closed = true
    break
  end
  Kernel.sleep 0.05
end
slow_sock.close
slow.shutdown(grace: 0.5)
check 'inline: a slow reader is closed by write_timeout', slow_closed

def serve_once(log)
  again = Kiln::Server::Event.new(->(ctx) { ctx.res.text('again') }, nil, log:, port: 0)
  again.start
  again_sock = TCPSocket.new('127.0.0.1', again.port)
  again_sock.write("GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
  answered = read_until_closed(again_sock, 2).end_with?('again')
  again_sock.close
  again.shutdown(grace: 0.5)
  answered
end

reused = Array.new(2) do
  answered = serve_once(log)
  GC.start
  answered
end
check 'a later server keeps the loop fd after an earlier one is collected', reused == [true, true]

blocked_started = Queue.new
deadline_router = Kiln::Router.new
deadline_router.get('/blocked', lambda do |ctx|
  blocked_started << true
  Kernel.sleep 0.5
  ctx.res.text('late')
end)
deadline_router.get('/fast', ->(ctx) { ctx.res.text('fast') })
deadline_server = Kiln::Server::Event.new(deadline_router, nil, log: log, port: 0,
                                                                request_timeout: 0.05)
deadline_server.start
blocked_client = Thread.new do
  exchange(deadline_server.port, "GET /blocked HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
end
blocked_started.pop
fast_started = Kiln.now
fast_reply = exchange(deadline_server.port, "GET /fast HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
fast_elapsed = Kiln.now - fast_started
blocked_reply = blocked_client.value
check 'a blocked handler gets 504 at its deadline', blocked_reply.start_with?('HTTP/1.1 504 ') &&
                                                    deadline_server.killed == 1
check 'a blocked handler does not stall the next request', fast_reply.end_with?('fast') && fast_elapsed < 0.3
deadline_server.shutdown(grace: 1)
