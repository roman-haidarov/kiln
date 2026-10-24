require 'kiln'
require 'socket'
require 'stringio'
require 'test/support'

def check(label, passed)
  raise "FAIL #{label}" unless passed

  puts "ok   #{label}"
end

CALLS = Queue.new
LANE_GATE = Queue.new
LANE_STARTED = Queue.new
SHUTDOWN_CALLS = Queue.new
LONG_STARTED = Queue.new
log = Kiln::Observability::Log.new(StringIO.new)
router = Kiln::Routing::Router.new
                              .get('/', ->(ctx) { ctx.res.text("Hello, World!\n") })
                              .get('/sleep', lambda { |ctx|
                                               LANE_STARTED << 1
                                               LANE_GATE.pop(timeout: 30)
                                               ctx.res.text("slept\n")
                                             })
                              .get('/long', lambda { |ctx|
                                              LONG_STARTED << 1
                                              Kernel.sleep 3
                                              ctx.res.text("never\n")
                                            })
                              .get('/count', lambda { |ctx|
                                               CALLS << 1
                                               ctx.sleep(0.05)
                                               ctx.res.text("counted\n")
                                             })
                              .get('/shutdown-pipe', lambda { |ctx|
                                                       SHUTDOWN_CALLS << 1
                                                       ctx.sleep(0.05)
                                                       ctx.res.text("piped\n")
                                                     })
                              .seal!
lanes = Kiln::Server::Event.new(router, nil, log: log, port: 0, handlers: 4)
lanes.start
lp = lanes.port
slow_result = Queue.new
slow = Thread.new { slow_result << exchange(lp, "GET /sleep HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n") }
LANE_STARTED.pop(timeout: 10)
fast = exchange(lp, "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
slow_pending = slow_result.empty?
LANE_GATE << 1
slow.join
check 'lanes: a waiting handler does not block another connection',
      fast.end_with?("Hello, World!\n") && slow_pending && slow_result.pop.end_with?("slept\n")
batch = (+'').b
15.times { batch << "GET / HTTP/1.1\r\nHost: x\r\n\r\n" }
batch << "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
check 'lanes: 16 pipelined requests keep their order', exchange(lp, batch).scan('HTTP/1.1 200 ').size == 16
o = exchange(lp, "GET /count HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\nGET /count HTTP/1.1\r\nHost: x\r\n\r\n")
Kernel.sleep 0.2
check 'lanes: request after Connection: close is not executed', o.scan('HTTP/1.1 200 ').size == 1 && CALLS.size == 1
CALLS.clear
o = exchange(lp,
             "GET /count HTTP/1.0\r\nConnection: keep-alive, close\r\n\r\n" \
             "GET /count HTTP/1.0\r\nConnection: keep-alive\r\n\r\n")
Kernel.sleep 0.2
check 'lanes: HTTP/1.0 with both keep-alive and close stops after one request',
      o.scan(' 200 ').size == 1 && CALLS.size == 1
waiting = Queue.new
graceful_client = Thread.new do
  data = (1..3).map do |i|
    "GET /shutdown-pipe HTTP/1.1\r\nHost: x\r\n#{"Connection: close\r\n" if i == 3}\r\n"
  end.join
  waiting << exchange(lp, data, 3.0)
end
SHUTDOWN_CALLS.pop
left = lanes.shutdown(grace: 2)
graceful_client.join
pipe_response = waiting.pop
check 'lanes: shutdown finishes every request already parsed from a pipeline',
      left.zero? && SHUTDOWN_CALLS.size == 2 && pipe_response.scan('HTTP/1.1 200 ').size == 3 && lanes.connections.zero?
stuck = Kiln::Server::Event.new(router, nil, log: log, port: 0, handlers: 2)
stuck.start
stuck_data = (1..3).map { |i| "GET /long HTTP/1.1\r\nHost: x\r\n#{"Connection: close\r\n" if i == 3}\r\n" }.join
stuck_client = Thread.new { exchange(stuck.port, stuck_data, 3.0) }
LONG_STARTED.pop
t0 = Kiln::Runtime.now
stuck_left = stuck.shutdown(grace: 0.2)
took = Kiln::Runtime.now - t0
stuck_client.join
check 'lanes: grace expired -> active and queued handlers are counted',
      stuck_left == 3 && took < 2.0 && stuck.connections.zero?
after_stuck = Kiln::Server::Event.new(router, nil, log: log, port: 0)
restarted = begin
  after_stuck.start
  after_stuck.shutdown(grace: 0.5)
  true
rescue IOError
  false
end
check 'lanes: a new server starts in the same process after a grace cutoff', restarted

class CrashingPump < Kiln::Server::Event
  def serve(_src, _scan, _meta)
    raise 'pump crashed'
  end
end
crashed = CrashingPump.new(router, nil, log: log, port: 0, handlers: 1)
crashed.start
exchange(crashed.port, "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", 0.5)
t0 = Kiln::Runtime.now
crashed.shutdown(grace: 0.2)
check 'lanes: shutdown returns in bounded time when the loop thread has died', Kiln::Runtime.now - t0 < 3.0

closing = Kiln::Server::Event.new(router, nil, log: log, port: 0, handlers: 2)
closing.start
pipe_out = Queue.new
CALLS.clear
pipe_client = Thread.new do
  pipe_out << exchange(closing.port, "GET /count HTTP/1.1\r\nHost: x\r\n\r\nGET /count HTTP/1.1\r\nHost: x\r\n\r\n",
                       3.0)
end
CALLS.pop(timeout: 2)
closing.shutdown(grace: 2)
pipe_client.join
replies = pipe_out.pop
first_end = replies.index("counted\n")
check 'lanes: during shutdown only the last response on a connection says Connection: close',
      replies.scan('HTTP/1.1 200 ').size == 2 && replies.scan('Connection: close').size == 1 &&
      first_end && !replies.byteslice(
        0, first_end
      ).include?('Connection: close')

late_app = ->(ctx) { ctx.res.text("ran\n") }
expired = Kiln::Server::Event.new(late_app, nil, log:, port: 0, handlers: 1, request_timeout: 0.000001)
expired.start
late_replies = Array.new(20) { exchange(expired.port, "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", 1.0) }
expired.shutdown(grace: 0.5)
late_ok = late_replies.all? { |reply| reply.start_with?('HTTP/1.1 504 ') && reply.end_with?("deadline exceeded\n") }
check 'lanes: a job taken after its deadline is answered with 504, never with its untouched response', late_ok

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

def read_responses(sock, count, seconds = 10.0)
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
    next if chunk == :wait_readable
    break unless chunk.is_a?(String)

    out << chunk
  end
  out
end

SLOW_GATE = Queue.new
SLOW_STARTED = Queue.new
SLOW_DONE = Queue.new
order_router = Kiln::Routing::Router.new
                                    .get('/slow', lambda { |ctx|
                                                    SLOW_STARTED << 1
                                                    SLOW_GATE.pop(timeout: 30)
                                                    SLOW_DONE << 1
                                                    ctx.res.text('slow')
                                                  })
                                    .get('/nap', lambda { |ctx|
                                                   Kernel.sleep 0.2
                                                   ctx.res.text('nap')
                                                 })
                                    .get('/fast', ->(ctx) { ctx.res.text('fast') })
                                    .seal!
order_server = Kiln::Server::Event.new(order_router, nil, log: log, port: 0, handlers: 2, request_timeout: 60)
order_server.start
slow_sock = TCPSocket.new('127.0.0.1', order_server.port)
slow_sock.write("GET /slow HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
slow_started = !SLOW_STARTED.pop(timeout: 10).nil?
fast_results = Queue.new
fast_threads = Array.new(4) do
  Thread.new do
    sock = TCPSocket.new('127.0.0.1', order_server.port)
    served = 0
    while served < 20
      sock.write("GET /fast HTTP/1.1\r\nHost: x\r\n\r\n")
      got = read_responses(sock, 1)
      break unless got.start_with?('HTTP/1.1 200 ') && got.end_with?('fast')

      served += 1
    end
    sock.close
    fast_results << served
  end
end
fast_threads.each(&:join)
fast_served = 0
4.times { fast_served += fast_results.pop }
slow_waiting = SLOW_DONE.empty?
SLOW_GATE << 1
slow_body = read_until_closed(slow_sock, 10)
slow_sock.close
check 'hol_slow_handler',
      slow_started && slow_waiting && fast_served == 80 && slow_body.start_with?('HTTP/1.1 200 ') &&
      slow_body.end_with?('slow')
mixed_sock = TCPSocket.new('127.0.0.1', order_server.port)
mixed_sock.write("GET /nap HTTP/1.1\r\nHost: x\r\n\r\nGET /fast HTTP/1.1\r\nHost: x\r\n\r\nGET /fast HTTP/1.1\r\nHost: x\r\n\r\n")
mixed = read_responses(mixed_sock, 3)
mixed_sock.close
slow_at = mixed.index('nap')
fast_at = mixed.index('fast')
second_fast = mixed.index('fast', fast_at + 4) if fast_at
check 'pipelined_order_mixed',
      mixed.scan('HTTP/1.1 200 ').size == 3 && slow_at && fast_at && second_fast &&
      slow_at < fast_at && fast_at < second_fast
wait_for { order_server.in_flight.zero? }
check 'busy_cleanup', order_server.in_flight.zero?
order_server.shutdown(grace: 1)
