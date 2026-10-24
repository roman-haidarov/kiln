require 'kiln'
require 'socket'
require 'stringio'
require 'test/support'

Thread.current

class PressureServer < Kiln::Server::Event
  attr_accessor :reports

  def send_fixed(ctx, slot, gen, keep)
    super
    @reports << Kiln::Uv.kiln_uv_backlog(slot, gen) if ctx.req.path == '/large'
  end
end

def need(label, value)
  raise label unless value
end

body = 'x' * 1_048_576
calls = Queue.new
router = Kiln::Routing::Router.new
                              .get('/after-error', ->(ctx) { calls << true; ctx.res.text('unexpected') })
                              .get('/large', ->(ctx) { ctx.res.text(body) })
                              .get('/small', ->(ctx) { ctx.res.text('small') })
                              .get('/slow', ->(ctx) { ctx.sleep(0.15); ctx.res.text('FIRST') })
                              .seal!
[0, 2].each do |handlers|
  server = PressureServer.new(router, nil, port: 0, handlers: handlers, write_timeout: 10,
                              log: Kiln::Observability::Log.new(StringIO.new))
  server.reports = Queue.new
  server.start
  sock = TCPSocket.new('127.0.0.1', server.port)
  sock.write(("GET /large HTTP/1.1\r\nHost: x\r\n\r\n" * 31) +
             "GET /large HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
  first = server.reports.pop(timeout: 3)
  need('started', !first.nil?)
  Kernel.sleep 0.2
  need('paused', server.reports.size < 30)
  other = exchange(server.port, "GET /small HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
  need('other connection', other.end_with?('small'))
  bytes = 0
  deadline = Kiln::Runtime.now + 10
  loop do
    left = deadline - Kiln::Runtime.now
    need('drain deadline', left.positive?)
    ready, = IO.select([sock], nil, nil, left)
    need('drain readable', ready)
    chunk = sock.read_nonblock(65_536, exception: false)
    break if chunk.nil?
    next if chunk == :wait_readable

    bytes += chunk.bytesize
  end
  need('resumed', bytes > 32 * 1_048_576)
  backlog = [first]
  31.times { backlog << server.reports.pop(timeout: 3) }
  need('completed', backlog.none?(&:nil?))
  need('bounded', backlog.max < 2 * 1_048_576)
  sock.close
  server.shutdown(grace: 1)
  puts "ok pressure handlers=#{handlers}"
end

server = Kiln::Server::Event.new(router, nil, port: 0, handlers: 2,
                                log: Kiln::Observability::Log.new(StringIO.new))
server.start
bad = ["GET / HTTP/1.1\r\nConnection: close\r\n\r\n",
       "CONNECT host:80 HTTP/1.1\r\nHost: x\r\n\r\n",
       "GET badtarget HTTP/1.1\r\nHost: x\r\n\r\n"]
bad.each do |request|
  raw = exchange(server.port, "GET /slow HTTP/1.1\r\nHost: x\r\n\r\n" + request +
                              "GET /after-error HTTP/1.1\r\nHost: x\r\n\r\n")
  need('first response', raw.start_with?('HTTP/1.1 200 '))
  need('second response', raw.include?("FIRSTHTTP/1.1 #{request.start_with?('CONNECT') ? 501 : 400} "))
  need('stopped after error', calls.empty?)
end
server.shutdown(grace: 1)
puts 'ok ordered errors'

started = Queue.new
release = Queue.new
effects = Queue.new
router = Kiln::Routing::Router.new
                              .get('/small', ->(ctx) { ctx.res.text('unread') })
                              .get('/hold', ->(ctx) { started << true; release.pop; ctx.res.text('held') })
                              .get('/effect', ->(ctx) { effects << true; ctx.res.text('effect') })
                              .seal!
server = Kiln::Server::Event.new(router, nil, port: 0, handlers: 2,
                                log: Kiln::Observability::Log.new(StringIO.new))
server.start
sock = TCPSocket.new('127.0.0.1', server.port)
sock.write("GET /small HTTP/1.1\r\nHost: x\r\n\r\nGET /hold HTTP/1.1\r\nHost: x\r\n\r\n" +
           ("GET /effect HTTP/1.1\r\nHost: x\r\n\r\n" * 10))
need('handler started', started.pop(timeout: 3))
need('unread response', sock.wait_readable(3))
sock.close
Kernel.sleep 0.1
release << true
Kernel.sleep 0.1
need('disconnected requests cancelled', effects.empty?)
server.shutdown(grace: 1)
puts 'ok disconnected queue'
