require 'kiln'
require 'socket'
require 'stringio'
require 'test/support'

def check(label, passed)
  raise "FAIL #{label}" unless passed

  puts "ok   #{label}"
end

def chunked(data, size)
  out = (+'').b
  offset = 0
  while offset < data.bytesize
    piece = data.byteslice(offset, size)
    out << piece.bytesize.to_s(16) << "\r\n" << piece << "\r\n"
    offset += size
  end
  out << "0\r\nX-Sum: #{data.bytesize}\r\n\r\n"
end

def send_all(sock, data)
  sent = 0
  sent += sock.write(data.byteslice(sent, 65_536)) while sent < data.bytesize
  sent
rescue IOError, SystemCallError
  sent
end

def upload(port, head, body, seconds = 6.0)
  sock = TCPSocket.new('127.0.0.1', port)
  sock.write(head)
  writer = Thread.new { send_all(sock, body) }
  reply = read_until_closed(sock, seconds)
  writer.join(1)
  sock.close
  reply
end

UPLOAD = ('0123456789abcdef' * 262_144).b.freeze
SMALL = ('abcdefgh' * 512).b.freeze
log = Kiln::Observability::Log.new(StringIO.new)
router = Kiln::Routing::Router.new
router.post('/count', lambda { |ctx|
  payload = ctx.req.payload
  total = 0
  chunks = 0
  payload.each do |chunk|
    total += chunk.bytesize
    chunks += 1
  end
  ctx.res.text("streamed=#{ctx.req.streamed?} total=#{total} chunks=#{chunks.positive?}")
}, limit: 8 << 20)
router.post('/same', ->(ctx) { ctx.res.text(ctx.req.body == UPLOAD ? 'same' : "differs #{ctx.req.body.bytesize}") },
            limit: 8 << 20)
router.post('/small', ->(ctx) { ctx.res.text(ctx.req.body == SMALL ? 'small' : 'other') })
router.post('/default', ->(ctx) { ctx.res.text("len=#{ctx.req.body.bytesize}") })
router.post('/zero', lambda { |ctx|
  payload = ctx.req.payload
  first = payload.read(0)
  ctx.res.text("zero=#{first.bytesize} len=#{payload.read_all.bytesize}")
})
router.post('/tiny', ->(ctx) { ctx.res.text('tiny') }, limit: 16)
router.post('/reject', ->(ctx) { ctx.res.text('denied', status: 401) })
router.post('/slow', lambda { |ctx|
  total = 0
  ctx.req.payload.each do |chunk|
    total += chunk.bytesize
    Kernel.sleep 0.001
  end
  ctx.res.text("slow=#{total}")
}, limit: 8 << 20)
router.scope('/limited', limit: 32) do |scope|
  scope.post('/in', ->(ctx) { ctx.res.text("in=#{ctx.req.body.bytesize}") })
end
router.seal!

[[:event, {}], [:event, { handlers: 2 }], [:base, {}]].each do |backend, extra|
  label = extra.empty? ? backend.to_s : "#{backend} lanes"
  server = Kiln::Server.new(router, log: log, backend: backend, host: '127.0.0.1', port: 0,
                                         buffer_body: 1024, request_timeout: 10.0, **extra)
  server.start
  port = server.port
  size = UPLOAD.bytesize

  reply = upload(port, "POST /count HTTP/1.1\r\nHost: x\r\nContent-Length: #{size}\r\nConnection: close\r\n\r\n",
                 UPLOAD)
  check "#{label}: a 4 MiB body is read in chunks", reply.end_with?("streamed=true total=#{size} chunks=true")

  reply = upload(port, "POST /same HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n",
                 chunked(UPLOAD, 70_000))
  check "#{label}: a chunked 4 MiB body arrives intact", reply.end_with?('same')

  reply = upload(port, "POST /slow HTTP/1.1\r\nHost: x\r\nContent-Length: #{size}\r\nConnection: close\r\n\r\n",
                 UPLOAD, 15.0)
  check "#{label}: a slow reader gets the whole body", reply.end_with?("slow=#{size}")

  reply = exchange(port, "POST /small HTTP/1.1\r\nHost: x\r\nContent-Length: #{SMALL.bytesize}\r\n" \
                         "Connection: close\r\n\r\n#{SMALL}")
  check "#{label}: a body above buffer_body still reads as req.body", reply.end_with?('small')

  reply = upload(port, "POST /default HTTP/1.1\r\nHost: x\r\nContent-Length: #{size}\r\nConnection: close\r\n\r\n",
                 UPLOAD)
  check "#{label}: a route without a limit keeps max_body", reply.start_with?('HTTP/1.1 413 ')

  reply = upload(port, "POST /default HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n",
                 chunked(UPLOAD, 65_536))
  check "#{label}: a chunked body past max_body is refused while it is read", reply.start_with?('HTTP/1.1 413 ')

  reply = exchange(port, "POST /tiny HTTP/1.1\r\nHost: x\r\nContent-Length: 20\r\nConnection: close\r\n\r\n#{'t' * 20}")
  check "#{label}: a route limit refuses a buffered body before the handler", reply.start_with?('HTTP/1.1 413 ')

  reply = exchange(port, "POST /limited/in HTTP/1.1\r\nHost: x\r\nContent-Length: 40\r\nConnection: close\r\n\r\n" \
                         "#{'s' * 40}")
  inside = exchange(port, "POST /limited/in HTTP/1.1\r\nHost: x\r\nContent-Length: 30\r\nConnection: close\r\n\r\n" \
                          "#{'s' * 30}")
  check "#{label}: a scope limit applies to its routes", reply.start_with?('HTTP/1.1 413 ') && inside.end_with?('in=30')

  sock = TCPSocket.new('127.0.0.1', port)
  sock.write("POST /default HTTP/1.1\r\nHost: x\r\nContent-Length: 5000\r\nExpect: 100-continue\r\n" \
             "Connection: close\r\n\r\n")
  interim = collect_until(sock, 2) { |buf| buf.include?("100 Continue\r\n\r\n") }
  sock.write('c' * 5000)
  final = read_until_closed(sock, 2)
  sock.close
  check "#{label}: 100 Continue is sent when the handler reads a streamed body",
        interim.start_with?('HTTP/1.1 100 Continue') && final.end_with?('len=5000')

  sock = TCPSocket.new('127.0.0.1', port)
  sock.write("POST /reject HTTP/1.1\r\nHost: x\r\nContent-Length: 5000\r\nExpect: 100-continue\r\n\r\n")
  denied = read_until_closed(sock, 2)
  sock.close
  check "#{label}: a handler that refuses an Expect body never sees 100 Continue",
        denied.start_with?('HTTP/1.1 401 ') && !denied.include?('100 Continue') && denied.include?('Connection: close')

  reply = exchange(port, "POST /default HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n" \
                         "Connection: close\r\n\r\n" \
                         "zz\r\nab\r\n0\r\n\r\n")
  check "#{label}: a malformed chunk size -> 400", reply.start_with?('HTTP/1.1 400 ')
  check "#{label}: a malformed chunked body is reported the same way on every backend",
        reply.end_with?("malformed request body\n")

  reply = exchange(port, "POST /zero HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n" \
                         "3\r\nabc\r\n0\r\n\r\n")
  check "#{label}: reading zero bytes of a chunked body returns an empty string", reply.end_with?('zero=0 len=3')

  reply = exchange(port, "POST /default HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n" \
                         "Connection: close\r\n\r\n" \
                         "FFFFFFFFFFFFFFFFFFFFFFFF\r\n")
  check "#{label}: a chunk size past every limit -> 413", reply.start_with?('HTTP/1.1 413 ')

  pipelined = exchange(port, "POST /default HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n" \
                             "3\r\nabc\r\n0\r\n\r\nGET /nothing HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
  body_index = pipelined.index('len=3')
  missing_index = pipelined.index('HTTP/1.1 404 ')
  check "#{label}: a request pipelined after a chunked body is served in order",
        body_index && missing_index && body_index < missing_index
  server.shutdown(grace: 1.0)
end

stalled = Kiln::Routing::Router.new
stalled.post('/wait', ->(ctx) { ctx.res.text("len=#{ctx.req.body.bytesize}") })
stalled.post('/deaf', lambda { |ctx|
  Thread.current[:kiln_deadline] = nil
  ctx.res.text("len=#{ctx.req.body.bytesize}")
})
stalled.get('/', ->(ctx) { ctx.res.text('alive') })
stalled.seal!

[[:event, {}], [:event, { handlers: 1 }], [:base, {}]].each do |backend, extra|
  label = extra.empty? ? backend.to_s : "#{backend} lanes"
  server = Kiln::Server.new(stalled, log: log, backend: backend, host: '127.0.0.1', port: 0, buffer_body: 16,
                                          request_timeout: 0.3, read_timeout: 5.0, **extra)
  server.start
  port = server.port
  %w[/wait /deaf].each do |path|
    sock = TCPSocket.new('127.0.0.1', port)
    sock.write("POST #{path} HTTP/1.1\r\nHost: x\r\nContent-Length: 100000\r\nConnection: close\r\n\r\nstart")
    started = Kiln::Runtime.now
    reply = read_until_closed(sock, 4)
    took = Kiln::Runtime.now - started
    sock.close
    check "#{label}: a handler waiting on a stalled body #{path} gets 504 at its deadline",
          reply.start_with?('HTTP/1.1 504 ') && took < 2.0
    check "#{label}: the server keeps serving after #{path} expired",
          exchange(port, "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n").end_with?('alive') &&
          exchange(port, "POST /wait HTTP/1.1\r\nHost: x\r\nContent-Length: 40\r\nConnection: close\r\n\r\n#{'w' * 40}")
            .end_with?('len=40')
  end
  server.shutdown(grace: 1.0)
end

payload = Kiln::HTTP::Payload.buffered('hello world'.b, nil)
check 'a buffered payload reads in pieces',
      payload.read(5) == 'hello' && payload.read(100) == ' world' && payload.read.nil?
limited = Kiln::HTTP::Payload.buffered('hello world'.b, 4)
refused = begin
  limited.read_all
  false
rescue Kiln::HTTP::PayloadTooLarge
  true
end
check 'a buffered payload enforces its limit', refused
tested = Kiln::Testing.call(router, 'POST', '/small', body: SMALL)
check 'Testing.call serves payload routes', tested.body == 'small'
log.close
