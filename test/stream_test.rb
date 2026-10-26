require 'kiln'
require 'stringio'
require 'test/support'

def check(label, passed)
  raise "FAIL #{label}" unless passed

  puts "ok   #{label}"
end

def raises(label, klass, fragment)
  yield
  raise "FAIL #{label}: nothing raised"
rescue klass => e
  check(label, e.message.include?(fragment))
end

def dechunk(data)
  out = (+'').b
  pos = 0
  loop do
    eol = data.index("\r\n", pos)
    return nil unless eol

    size = data.byteslice(pos, eol - pos).to_i(16)
    return out if size.zero? && data.byteslice(eol, 4) == "\r\n\r\n"

    out << data.byteslice(eol + 2, size)
    pos = eol + 2 + size + 2
  end
end

def split_reply(raw)
  cut = raw.index("\r\n\r\n")
  return ['', ''] unless cut

  [raw.byteslice(0, cut), raw.byteslice(cut + 4, raw.bytesize - cut - 4)]
end

def ask(port, text, seconds = 3)
  sock = TCPSocket.new('127.0.0.1', port)
  sock.write(text)
  reply = read_until_closed(sock, seconds)
  sock.close
  reply
end

def get(port, path) = ask(port, "GET #{path} HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n")

BIG = 'b' * 20_000
GONE = Queue.new
TRACE = Queue.new

def build_router
  router = Kiln::Routing::Router.new
  router.get('/chunks', lambda do |ctx|
    ctx.res.stream(type: 'text/plain') do |out|
      out.write('a')
      out.flush
      out << BIG
      out.write('c')
    end
  end)
  router.get('/events', lambda do |ctx|
    ctx.res.sse do |out|
      out.event("line1\nline2", event: 'greet', id: 7, retry_ms: 1500)
      out.comment('ping')
      out.event('')
    end
  end)
  router.get('/slow', lambda do |ctx|
    ctx.res.stream do |out|
      out.write('one')
      out.flush
      Kernel.sleep 0.2
      Kiln::Runtime.check!
      out.write('two')
    end
  end)
  router.get('/forever', lambda do |ctx|
    ctx.res.sse do |out|
      loop do
        out.event('tick')
        Kernel.sleep 0.02
      end
    rescue Kiln::Runtime::ClientGone
      GONE << :gone
      raise
    end
  end)
  router.get('/flood', lambda do |ctx|
    ctx.res.stream do |out|
      chunk = 'z' * 65_536
      begin
        4096.times { out.write(chunk) }
        GONE << :finished
      rescue Kiln::Runtime::ClientGone
        GONE << :gone
        raise
      end
    end
  end)
  router.get('/broken', lambda do |ctx|
    ctx.res.stream do |out|
      out.write('partial')
      out.flush
      raise 'boom in stream'
    end
  end)
  router.get('/replaced', lambda do |ctx|
    ctx.res.stream { |out| out.write('secret') }
    raise Kiln::HTTP::BadRequest, 'invalid input'
  end)
  router.get('/watch', lambda do |ctx|
    ctx.res.sse do |out|
      until out.closed?
        out.comment('wait')
        Kernel.sleep 0.02
      end
      TRACE << :closed
    end
  end)
  router.get('/health', ->(ctx) { ctx.res.text('ok') })
  router.seal!
end

puts '-- writer'
check 'first chunk head', Kiln::HTTP::Stream.chunk_head(5, false) == "5\r\n"
check 'later chunk head closes the previous chunk, size in hex', Kiln::HTTP::Stream.chunk_head(26, true) == "\r\n1a\r\n"
check 'sse event fields',
      Kiln::HTTP::Stream.sse("a\r\nb", 'e', 3, 10) == "event: e\nid: 3\nretry: 10\ndata: a\ndata: b\n\n"
check 'sse empty data', Kiln::HTTP::Stream.sse('', nil, nil, nil) == "data: \n\n"
sink = []
writer = Kiln::HTTP::Stream.new(->(prefix, bytes) { sink << (prefix + bytes) }, -> { false }, true)
writer.write('ab')
check 'write buffers until flush', sink.empty?
writer.flush
check 'flush sends one chunk head and its data', sink == ["2\r\nab"]
writer.write('x' * Kiln::HTTP::Stream::FLUSH_AT)
check 'a large write goes out at once, its head carrying the previous CRLF',
      sink.size == 2 && sink[1].start_with?("\r\n4000\r\n")
check 'ending closes the last chunk', writer.ending == "\r\n0\r\n\r\n"
check 'ending with nothing sent', Kiln::HTTP::Stream.new(->(_p, _b) {}, -> { false }, true).ending == "0\r\n\r\n"
writer.flush
check 'empty flush sends nothing', sink.size == 2
writer.write('')
writer.flush
check 'empty write sends nothing', sink.size == 2
raises('event name with a line break', ArgumentError, 'event') { writer.event('x', event: "a\nb") }
raises('id with a line break', ArgumentError, 'id') { writer.event('x', id: "1\r2") }
raises('comment with a line break', ArgumentError, 'comment') { writer.comment("a\nb") }
raises('stream needs a block', ArgumentError, 'block') { Kiln::HTTP::Response.new.stream }

puts '-- testing helper'
helper_app = build_router
streamed = Kiln::Testing.call(helper_app, 'GET', '/chunks')
check 'Testing collects a stream', streamed.body == "a#{BIG}c" && streamed.headers['Content-Type'] == 'text/plain'
sse = Kiln::Testing.call(helper_app, 'GET', '/events')
check 'Testing collects SSE', sse.body.start_with?("event: greet\nid: 7\nretry: 1500\ndata: line1\ndata: line2\n\n") &&
                              sse.headers['Content-Type'] == 'text/event-stream; charset=utf-8' &&
                              sse.headers['Cache-Control'] == 'no-cache'
replaced = Kiln::Testing.call(helper_app, 'GET', '/replaced')
check 'a mapped error cancels an earlier stream', replaced.status == 400 && replaced.body == "invalid input\n" &&
                                                  !replaced.streaming?

log_io = StringIO.new
log = Kiln::Observability::Log.new(log_io)
[[:event, 0], [:event, 2], [:base, 0]].each do |backend, handlers|
  name = backend == :event ? "event/#{handlers}" : 'base'
  options = { log:, port: 0, host: '127.0.0.1', backend:, request_timeout: 0.1, write_timeout: 0.5 }
  options[:handlers] = handlers if backend == :event
  server = Kiln::Server.new(Kiln::Middleware::Rescue.new(build_router, log), **options)
  server.start
  port = server.port

  head, body = split_reply(get(port, '/chunks'))
  check "#{name}: chunked head", head.include?('Transfer-Encoding: chunked') && !head.include?('Content-Length')
  check "#{name}: chunked body", dechunk(body) == "a#{BIG}c"

  _, events = split_reply(get(port, '/events'))
  wire = "event: greet\nid: 7\nretry: 1500\ndata: line1\ndata: line2\n\n: ping\n\ndata: \n\n"
  check "#{name}: SSE wire format", dechunk(events) == wire

  old = ask(port, "GET /chunks HTTP/1.0\r\n\r\n")
  old_head, old_body = split_reply(old)
  check "#{name}: HTTP/1.0 stream is close-delimited", !old_head.include?('chunked') && old_body == "a#{BIG}c"

  heads = ask(port, "HEAD /chunks HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n")
  check "#{name}: HEAD sends the head only", heads.include?('Transfer-Encoding: chunked') && heads.end_with?("\r\n\r\n")

  first = "GET /chunks HTTP/1.1\r\nHost: t\r\n\r\n"
  piped = ask(port, "#{first}GET /health HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n")
  terminator = piped.index("0\r\n\r\n")
  second = piped.index('HTTP/1.1 200', 5)
  check "#{name}: pipelined reply waits for the stream",
        terminator && second && second > terminator && piped.end_with?('ok')

  _, slow = split_reply(get(port, '/slow'))
  check "#{name}: stream outlives request_timeout", dechunk(slow) == 'onetwo'

  sock = TCPSocket.new('127.0.0.1', port)
  sock.write("GET /forever HTTP/1.1\r\nHost: t\r\n\r\n")
  sock.readpartial(4096)
  sock.close
  check "#{name}: a closed client ends the stream", GONE.pop(timeout: 1.5) == :gone

  sock = TCPSocket.new('127.0.0.1', port)
  sock.write("GET /flood HTTP/1.1\r\nHost: t\r\n\r\n")
  check "#{name}: a client that does not read is cut off", GONE.pop(timeout: 6) == :gone
  sock.close

  broken = get(port, '/broken')
  check "#{name}: an error mid-stream aborts without a terminator",
        broken.include?('partial') && !broken.include?("0\r\n\r\n")
  broken_pipe = ask(port, "GET /broken HTTP/1.1\r\nHost: t\r\n\r\n" \
                          "GET /health HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n")
  check "#{name}: a broken stream does not send the next response", broken_pipe.scan('HTTP/1.1 ').size == 1
  replaced_wire = get(port, '/replaced')
  check "#{name}: a mapped error does not execute the old stream", replaced_wire.include?('400 Bad Request') &&
                                                                   !replaced_wire.include?('secret')
  check "#{name}: server still answers", get(port, '/health').end_with?('ok')

  watcher = TCPSocket.new('127.0.0.1', port)
  watcher.write("GET /watch HTTP/1.1\r\nHost: t\r\n\r\n")
  watcher.readpartial(4096)
  started = Kiln::Runtime.now
  server.shutdown(grace: 1.0)
  check "#{name}: shutdown ends an SSE loop through closed?",
        TRACE.pop(timeout: 1) == :closed && Kiln::Runtime.now - started < 0.7
  watcher.close
end
log.close
check 'stream errors are logged', log_io.string.include?('boom in stream')
puts 'done'
