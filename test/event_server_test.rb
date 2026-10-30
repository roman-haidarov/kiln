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
log = Kiln::Observability::Log.new(StringIO.new)
claim_job = Kiln::Server::Event::Job.new(nil, 0, 0, nil, false, Mutex.new)
claim_gate = Queue.new
claim_results = Queue.new
claim_threads = Array.new(2) do
  Thread.new do
    claim_gate.pop
    claim_results << claim_job.claim!
  end
end
2.times { claim_gate << true }
claim_values = Array.new(2) { claim_results.pop }
claim_threads.each(&:join)
check 'a streamed request can be claimed only once across threads', claim_values.count(true) == 1

router = Kiln::Routing::Router.new
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
                              .get('/deadline', lambda { |ctx|
                                                  ctx.res.text(Kiln::Runtime.deadline.positive? ? 'set' : 'unset')
                                                })
                              .get('/late', lambda { |ctx|
                                              Kernel.sleep 0.3
                                              Kiln::Runtime.check!
                                              ctx.res.text('never')
                                            })
                              .get('/hang', lambda { |ctx|
                                              HANG_STARTED << 1
                                              Kernel.sleep 0.5
                                              ctx.res.text("late\n")
                                            })
                              .get('/absolute', ->(ctx) { ctx.res.text("#{ctx.req.path}|#{ctx.req.headers['host']}") })
                              .get('/noncooperative', lambda do |ctx|
                                                        Kernel.sleep 0.3
                                                        ctx.res.headers['Content-Encoding'] = 'gzip'
                                                        ctx.res.text('late')
                                                      end)
                              .seal!

pipe_marker = -> {}
old_pipe_handler = Signal.trap('PIPE', pipe_marker)
pipe_server = Kiln::Server::Event.new(router, log: log, port: 0, handlers: 0)
pipe_server.start
pipe_after_start = Signal.trap('PIPE', 'DEFAULT')
Signal.trap('PIPE', pipe_marker)
pipe_server.shutdown(grace: 0)
pipe_after_stop = Signal.trap('PIPE', 'DEFAULT')
Signal.trap('PIPE', old_pipe_handler)
check 'event server preserves the process SIGPIPE handler',
      pipe_after_start.equal?(pipe_marker) && pipe_after_stop.equal?(pipe_marker)

inline = Kiln::Server::Event.new(router, log: log, port: 0, request_timeout: 0.2, handlers: 0)
inline.start
ip = inline.port
absolute = exchange(ip, "GET http://example.test/absolute HTTP/1.1\r\nHost: ignored.test\r\nConnection: close\r\n\r\n")
check 'absolute-form target is routed and supplies its authority as Host',
      absolute.end_with?('/absolute|example.test')
star = exchange(ip, "OPTIONS * HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
check 'OPTIONS * is accepted by the event backend', star.start_with?('HTTP/1.1 204 ')
check 'non-OPTIONS asterisk target is rejected',
      exchange(ip, "GET * HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n").start_with?('HTTP/1.1 400 ')
check 'CONNECT receives 501 on the event backend',
      exchange(ip, "CONNECT example.test:443 HTTP/1.1\r\nHost: example.test\r\nConnection: close\r\n\r\n")
        .start_with?('HTTP/1.1 501 ')
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
o = read_until_closed(big_client, 2)
big_client.close
check 'inline: two large pipelined responses arrive whole and in order',
      o.scan('HTTP/1.1 200 ').size == 2 && o.scan(BIG_BODY.b).size == 2 && o.end_with?(BIG_BODY.b)
check 'inline: malformed request -> 400', exchange(ip, "GARBAGE\r\n\r\n").start_with?('HTTP/1.1 400 ')
check 'inline: missing Host on HTTP/1.1 -> 400',
      exchange(ip, "GET / HTTP/1.1\r\nConnection: close\r\n\r\n").start_with?('HTTP/1.1 400 ')
check 'inline: chunked request body reaches the handler',
      exchange(ip,
               "POST /echo HTTP/1.1\r\nHost: x\r\nConnection: close\r\n" \
               "Transfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n3;x=1\r\nabc\r\n0\r\n\r\n").end_with?('len=8')
check 'inline: a transfer coding other than chunked -> 501',
      exchange(ip,
               "POST /echo HTTP/1.1\r\nHost: x\r\n" \
               "Transfer-Encoding: gzip, chunked\r\n\r\n0\r\n\r\n").start_with?('HTTP/1.1 501 ')
check 'inline: handler error -> 500',
      exchange(ip, "GET /boom HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n").start_with?('HTTP/1.1 500 ')
check 'inline: unknown route -> 404',
      exchange(ip, "GET /none HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n").start_with?('HTTP/1.1 404 ')
o = exchange(ip, "GET /count HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\nGET /count HTTP/1.1\r\nHost: x\r\n\r\n")
check 'inline: request after Connection: close is not executed', o.scan('HTTP/1.1 200 ').size == 1 && CALLS.size == 1
CALLS.clear
o = exchange(ip, "GET /count HTTP/1.0\r\n\r\nGET /count HTTP/1.0\r\n\r\n")
check 'inline: HTTP/1.0 without keep-alive stops after one request', o.scan(' 200 ').size == 1 && CALLS.size == 1
check 'inline: request deadline is visible to Kiln::Runtime.deadline',
      exchange(ip, "GET /deadline HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n").end_with?('set')
check 'inline: Kiln::Runtime.check! after the deadline -> 504',
      exchange(ip, "GET /late HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n").start_with?('HTTP/1.1 504 ')
late_inline = exchange(ip, "GET /noncooperative HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
check 'inline: a late handler returns a clean 504 without interrupting the event loop',
      late_inline.start_with?('HTTP/1.1 504 ') && !late_inline.include?('Content-Encoding:') && inline.killed.zero? &&
      exchange(ip, "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n").end_with?("Hello, World!\n")
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
  exchange(ip, data, 1.0)
end
SHUTDOWN_CALLS.pop
pipe_shutdown_left = inline.shutdown(grace: 1)
pipe_response = pipe_client.value
check 'inline: shutdown finishes every request already parsed from a pipeline',
      pipe_shutdown_left.zero? && SHUTDOWN_CALLS.size == 2 && pipe_response.scan('HTTP/1.1 200 ').size == 3
check 'inline: shutdown releases connections', inline.connections.zero?
hung = Kiln::Server::Event.new(router, log: log, port: 0, handlers: 0)
hung.start
hung_data = (1..3).map { |i| "GET /hang HTTP/1.1\r\nHost: x\r\n#{"Connection: close\r\n" if i == 3}\r\n" }.join
hung_client = Thread.new { exchange(hung.port, hung_data, 1.0) }
HANG_STARTED.pop
hung_left = hung.shutdown(grace: 0.2)
hung_client.join
check 'inline: unfinished count includes queued requests when the handler is stopped', hung_left == 3

last = Kiln::Server::Event.new(router, log: log, port: 0, handlers: 0)
last.start
last_out = Queue.new
last_client = Thread.new { last_out << exchange(last.port, "GET /pause HTTP/1.1\r\nHost: x\r\n\r\n", 1.0) }
PAUSED.pop
last.shutdown(grace: 0.7)
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
  v6 = Kiln::Server::Event.new(router, log: log, host: '::1', port: 0, handlers: 0)
  v6.start
  v6_client = TCPSocket.new('::1', v6.port)
  v6_client.write("GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
  v6_served = read_until_closed(v6_client, 0.7).end_with?("Hello, World!\n")
  v6_client.close
  v6.shutdown(grace: 0)
end
check 'inline: listens on ::1 when the host has IPv6', v6_served

more = Kiln::Server::Event.new(router, log: log, port: 0)
more.start
mp = more.port
half = TCPSocket.new('127.0.0.1', mp)
half.write("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
half.shutdown(Socket::SHUT_WR)
half_body = read_until_closed(half, 0.7)
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

slow = Kiln::Server::Event.new(->(ctx) { ctx.res.text('z' * (8 << 20)) },
                               log: log, port: 0, write_timeout: 0.2)
slow.start
slow_sock = TCPSocket.new('127.0.0.1', slow.port)
slow_sock.write("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
wait_for { slow.connections.positive? }
slow_closed = false
slow_limit = Kiln::Runtime.now + 0.7
while Kiln::Runtime.now < slow_limit
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
  again = Kiln::Server::Event.new(->(ctx) { ctx.res.text('again') }, log:, port: 0)
  again.start
  again_sock = TCPSocket.new('127.0.0.1', again.port)
  again_sock.write("GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
  answered = read_until_closed(again_sock, 0.7).end_with?('again')
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
blocked_gate = Queue.new
deadline_router = Kiln::Routing::Router.new
deadline_router.get('/blocked', lambda do |ctx|
  blocked_started << true
  blocked_gate.pop(timeout: 1.5)
  ctx.res.text('late')
end)
deadline_router.get('/fast', ->(ctx) { ctx.res.text('fast') })
deadline_server = Kiln::Server::Event.new(deadline_router, log: log, port: 0,
                                                                request_timeout: 0.3, handlers: 2)
deadline_server.start
blocked_client = Thread.new do
  exchange(deadline_server.port, "GET /blocked HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
end
blocked_started.pop
fast_started = Kiln::Runtime.now
fast_reply = exchange(deadline_server.port, "GET /fast HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
fast_elapsed = Kiln::Runtime.now - fast_started
blocked_reply = blocked_client.value
blocked_gate << true
check 'a blocked handler gets 504 at its deadline', blocked_reply.start_with?('HTTP/1.1 504 ') &&
                                                    deadline_server.killed == 1
check 'a blocked handler does not stall the next request', fast_reply.end_with?('fast') && fast_elapsed < 2.5
deadline_server.shutdown(grace: 1)

stream_started = Queue.new
stream_release = Queue.new
stream_router = Kiln::Routing::Router.new.get('/stream', lambda do |ctx|
  ctx.res.headers['Content-Type'] = 'text/plain'
  ctx.res.stream do |out|
    stream_started << true
    stream_release.pop
    out.write('streamed')
  end
end).seal!
gzip_streams = Kiln::Middleware::Compress.new(stream_router, min_size: 1)
limited_streams = Kiln::Server::Event.new(gzip_streams, log: log, port: 0, max_streams: 1)
limited_streams.start
stream_client = TCPSocket.new('127.0.0.1', limited_streams.port)
stream_client.write("GET /stream HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
stream_started.pop(timeout: 1)
overflow_request = "GET /stream HTTP/1.1\r\nHost: x\r\nAccept-Encoding: gzip\r\nConnection: close\r\n\r\n"
overflow_stream = exchange(limited_streams.port, overflow_request)
bounded_stream = overflow_stream.start_with?('HTTP/1.1 503 ') && overflow_stream.end_with?("too many streams\n") &&
                 !overflow_stream.include?('Content-Encoding: gzip') &&
                 !overflow_stream.include?('Vary: Accept-Encoding')
check 'event stream overflow discards headers from the gzip representation', bounded_stream
stream_release << true
stream_reply = read_until_closed(stream_client, 0.7)
stream_client.close
limited_streams.shutdown(grace: 1)
check 'a stream below max_streams completes', stream_reply.include?('streamed')

drip = Kiln::Server::Event.new(router, log: log, port: 0)
drip.start
drip_req = "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
whole = exchange(drip.port, drip_req)
drip_sock = TCPSocket.new('127.0.0.1', drip.port)
drip_at = 0
while drip_at < drip_req.bytesize
  drip_sock.write(drip_req.byteslice(drip_at, 1))
  Kernel.sleep 0.001
  drip_at += 1
end
dripped = read_until_closed(drip_sock, 0.7)
drip_sock.close
check 'a request sent one byte at a time matches the whole request',
      whole.start_with?('HTTP/1.1 200 ') && dripped.start_with?('HTTP/1.1 200 ') &&
      whole.end_with?("Hello, World!\n") && dripped.end_with?("Hello, World!\n")
split_ok = true
split_at = 0
while split_at < 4
  cut = drip_req.bytesize - 4 + split_at
  split_sock = TCPSocket.new('127.0.0.1', drip.port)
  split_sock.write(drip_req.byteslice(0, cut))
  Kernel.sleep 0.05
  split_sock.write(drip_req.byteslice(cut, drip_req.bytesize - cut))
  split_out = read_until_closed(split_sock, 0.7)
  split_sock.close
  split_ok &&= split_out.start_with?('HTTP/1.1 200 ') && split_out.end_with?("Hello, World!\n")
  split_at += 1
end
check 'a write split before each of the last four header bytes matches',
      split_ok && whole.end_with?("Hello, World!\n")
huge = (+"GET / HTTP/1.1\r\nHost: x\r\n").b
pad = "X-Pad: #{'a' * 40}\r\n"
while huge.bytesize <= 16_384
  huge << pad
end
huge << "\r\n"
huge_sock = TCPSocket.new('127.0.0.1', drip.port)
huge_off = 0
while huge_off < huge.bytesize
  huge_n = huge.bytesize - huge_off
  huge_n = 64 if huge_n > 64
  begin
    huge_sock.write(huge.byteslice(huge_off, huge_n))
  rescue IOError, SystemCallError
    break
  end
  huge_off += huge_n
end
huge_out = read_until_closed(huge_sock, 2)
huge_sock.close
check 'a header larger than 16384 bytes sent 64 bytes at a time -> 431',
      huge_out.start_with?('HTTP/1.1 431 ')

def response_count(buf)
  count = 0
  offset = 0
  while offset < buf.bytesize
    cut = buf.index("\r\n\r\n", offset)
    break unless cut

    head = buf.byteslice(offset, cut - offset)
    mark = head.index('Content-Length: ')
    break unless mark

    start = head.getbyte(mark + 16)
    break unless start && start >= 48 && start <= 57

    length = head.byteslice(mark + 16, 16).to_i
    body_end = cut + 4 + length
    break if body_end > buf.bytesize

    count += 1
    offset = body_end
  end
  count
end

def read_responses(sock, count, seconds = 2.0)
  out = (+'').b
  limit = Kiln::Runtime.now + seconds
  while response_count(out) < count && Kiln::Runtime.now < limit
    ready, = IO.select([sock], nil, nil, limit - Kiln::Runtime.now)
    break unless ready

    chunk = begin
      sock.read_nonblock(65_536, exception: false)
    rescue IOError, SystemCallError
      nil
    end
    break unless chunk.is_a?(String)

    out << chunk
  end
  out
end

keep = TCPSocket.new('127.0.0.1', drip.port)
keep.write("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
keep_first = read_responses(keep, 1)
Kernel.sleep 0.05
keep.write("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
keep_second = read_responses(keep, 1)
check 'keep-alive: a request, a pause, and a second request are both 200 with the body',
      keep_first.start_with?('HTTP/1.1 200 ') && keep_first.end_with?("Hello, World!\n") &&
      keep_second.start_with?('HTTP/1.1 200 ') && keep_second.end_with?("Hello, World!\n")
post_body = ('z' * 100_000).b
keep.write("POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 100000\r\n\r\n".b + post_body)
posted = read_responses(keep, 1)
check 'keep-alive: a 100000-byte POST on the same socket reports that size',
      posted.start_with?('HTTP/1.1 200 ') && posted.end_with?('len=100000')
Kernel.sleep 0.05
keep.write("GET / HTTP/1.1\r\nHost: x\r\n\r\nGET /utf HTTP/1.1\r\nHost: x\r\n\r\n")
piped = read_responses(keep, 2)
hello_at = piped.index("Hello, World!\n")
utf_at = piped.b.index('привет'.b)
check 'keep-alive: two pipelined requests after an idle pause stay in order',
      piped.scan('HTTP/1.1 200 ').size == 2 && hello_at && utf_at && hello_at < utf_at
keep.close
drip.shutdown(grace: 0.5)
