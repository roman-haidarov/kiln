require 'kiln'
require 'socket'
require 'stringio'
require 'test/support'

def check(label, passed)
  raise "FAIL #{label}" unless passed

  puts "ok   #{label}"
end

CALLS = Queue.new
SHUTDOWN_CALLS = Queue.new
LONG_STARTED = Queue.new
log = Kiln::Log.new(StringIO.new)
router = Kiln::Router.new
                     .get('/', ->(ctx) { ctx.res.text("Hello, World!\n") })
                     .get('/sleep', lambda { |ctx|
                                      ctx.sleep(0.3)
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
Kernel.sleep 0.05
started = Kiln.now
fast = exchange(lp, "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
fast_took = Kiln.now - started
slow.join
check 'lanes: a waiting handler does not block another connection',
      fast.end_with?("Hello, World!\n") && fast_took < 0.2 && slow_result.pop.end_with?("slept\n")
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
t0 = Kiln.now
stuck_left = stuck.shutdown(grace: 0.2)
took = Kiln.now - t0
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
t0 = Kiln.now
crashed.shutdown(grace: 0.2)
check 'lanes: shutdown returns in bounded time when the loop thread has died', Kiln.now - t0 < 3.0

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
