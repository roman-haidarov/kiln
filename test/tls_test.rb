require 'kiln'
require 'openssl'
require 'socket'
require 'stringio'
require 'test/support'

def check(label, passed)
  raise "FAIL #{label}" unless passed

  puts "ok   #{label}"
end

def rejects(label)
  yield
  raise "FAIL #{label}: accepted"
rescue ArgumentError, IOError
  puts "ok   #{label}"
end

def tls_wait?(tcp, state, limit)
  left = limit - Kiln::Runtime.now
  return false if left <= 0

  if state == :wait_writable
    IO.select(nil, [tcp], nil, left)
  else
    IO.select([tcp], nil, nil, left)
  end
  true
end

def tls_open(port, limit)
  tcp = TCPSocket.new('127.0.0.1', port)
  context = OpenSSL::SSL::SSLContext.new
  context.verify_mode = OpenSSL::SSL::VERIFY_NONE
  ssl = OpenSSL::SSL::SSLSocket.new(tcp, context)
  ssl.hostname = 'localhost'
  loop do
    state = ssl.connect_nonblock(exception: false)
    break unless state == :wait_readable || state == :wait_writable
    return [nil, tcp] unless tls_wait?(tcp, state, limit)
  end
  [ssl, tcp]
rescue OpenSSL::SSL::SSLError, IOError, SystemCallError
  [nil, tcp]
end

def tls_write?(ssl, tcp, data, limit)
  sent = 0
  piece = nil
  while sent < data.bytesize
    piece ||= data.byteslice(sent, 16_384)
    wrote = ssl.syswrite_nonblock(piece, exception: false)
    if wrote == :wait_readable || wrote == :wait_writable
      return false unless tls_wait?(tcp, wrote, limit)
    elsif wrote.nil?
      return false
    else
      sent += wrote
      piece = wrote == piece.bytesize ? nil : piece.byteslice(wrote, piece.bytesize - wrote)
    end
  end
  true
end

def tls_read(ssl, tcp, limit)
  out = (+'').b
  loop do
    got = ssl.sysread_nonblock(65_536, exception: false)
    if got == :wait_readable || got == :wait_writable
      break unless tls_wait?(tcp, got, limit)
    elsif got.nil?
      break
    else
      out << got
    end
  end
  out
rescue OpenSSL::SSL::SSLError, IOError, SystemCallError
  out
end

def tls_exchange(port, data, seconds = 5.0)
  limit = Kiln::Runtime.now + seconds
  ssl, tcp = tls_open(port, limit)
  return :no_handshake if ssl.nil?

  tls_write?(ssl, tcp, data, limit)
  tls_read(ssl, tcp, limit)
ensure
  tcp&.close
end

def openssl_cli(port, alpn, request)
  `printf '#{request}' | openssl s_client -ign_eof -connect 127.0.0.1:#{port} -alpn #{alpn} -servername localhost 2>&1`
end

CERT = 'test/fixtures/tls_cert.pem'.freeze
KEY = 'test/fixtures/tls_key.pem'.freeze
UPLOAD = ('tls-body' * 400_000).b.freeze
log = Kiln::Observability::Log.new(StringIO.new)
router = Kiln::Routing::Router.new
router.get('/', ->(ctx) { ctx.res.text("scheme=#{ctx.req.scheme} tls=#{ctx.req.tls?} alpn=#{ctx.req.alpn}") })
router.get('/big', ->(ctx) { ctx.res.text('b' * 1_000_000) })
router.post('/up', ->(ctx) { ctx.res.text(ctx.req.body == UPLOAD ? 'same' : 'differs') }, limit: 8 << 20)
router.get('/ws', lambda { |ctx|
  ctx.res.websocket(ctx) { |ws| ws.each { |message| ws.send_text("echo:#{message.data}") } }
})
router.seal!

check 'OpenSSL is found at run time', Kiln::Transport::Tls.available?
tls = Kiln::Transport::Tls.new(cert: CERT, key: KEY)
listen = [Kiln::Transport::Listen.tcp('127.0.0.1', 0, tls: tls), Kiln::Transport::Listen.tcp('127.0.0.1', 0)]
server = Kiln::Server.new(router, nil, log: log, buffer_body: 4096, listen: listen)
server.start
secure = server.ports[0]
plain = server.ports[1]

reply = tls_exchange(secure, "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
check 'an HTTPS request is answered over TLS', reply.is_a?(String) && reply.end_with?('scheme=https tls=true alpn=')
check 'the plain listener of the same server stays HTTP',
      exchange(plain, "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n").end_with?('scheme=http tls=false alpn=')
big = tls_exchange(secure, "GET /big HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
check 'a 1 MB response crosses TLS intact', big.is_a?(String) && big.end_with?('b' * 1000) &&
                                            big.include?('Content-Length: 1000000')
upload = tls_exchange(secure, "POST /up HTTP/1.1\r\nHost: x\r\nContent-Length: #{UPLOAD.bytesize}\r\n" \
                              "Connection: close\r\n\r\n#{UPLOAD}", 10.0)
check 'a streamed 3 MB upload crosses TLS intact', upload.is_a?(String) && upload.end_with?('same')
pipelined = tls_exchange(secure,
                         "GET / HTTP/1.1\r\nHost: x\r\n\r\nGET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
check 'pipelined requests are answered over TLS', pipelined.is_a?(String) && pipelined.scan('HTTP/1.1 200 ').size == 2

frame = "\x81\x82\x01\x02\x03\x04".b + Kiln::HTTP::WsNative.kiln_ws_mask('hi', 2, 0x01020304)
closing = Kiln::HTTP::WsNative.kiln_ws_mask("\x03\xE8".b, 2, 0x01020304)
ws = tls_exchange(secure, "GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
                          "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n" \
                          "#{frame}\x88\x82\x01\x02\x03\x04#{closing}")
check 'a websocket works over TLS', ws.is_a?(String) && ws.start_with?('HTTP/1.1 101 ') && ws.include?('echo:hi')

cleartext = exchange(secure, "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
check 'plain HTTP on the TLS port gets no HTTP answer', !cleartext.include?('HTTP/1.1')

negotiated = openssl_cli(secure, 'h2,http/1.1', 'GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n')
check 'ALPN selects http/1.1 from h2,http/1.1', negotiated.include?('ALPN protocol: http/1.1') &&
                                                negotiated.include?('alpn=http/1.1')
refused = openssl_cli(secure, 'h2', '')
check 'ALPN without http/1.1 fails the handshake', refused.include?('no application protocol') ||
                                                   refused.include?('alert number 120')
server.shutdown(grace: 1.0)

gated = Kiln::Server.new(router, nil, log: log, host: '127.0.0.1', port: 0,
                                      tls: Kiln::Transport::Tls.new(cert: CERT, key: KEY),
                                      max_connection_rate: 1, header_timeout: 0.6)
gated.start
idle = TCPSocket.new('127.0.0.1', gated.port)
wait_for { gated.handshakes == 1 }
started = Kiln::Runtime.now
late = tls_exchange(gated.port, "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
waited = Kiln::Runtime.now - started
idle.close
check 'max_connection_rate holds new handshakes until a slot frees',
      late.is_a?(String) && late.end_with?('tls=true alpn=') && waited >= 0.3
gated.shutdown(grace: 0.5)

modern = Kiln::Transport::Tls.new(cert: CERT, key: KEY, min_version: '1.3', alpn: ['http/1.1'])
strict = Kiln::Server.new(router, nil, log: log, host: '127.0.0.1', port: 0, tls: modern)
strict.start
old = `openssl s_client -connect 127.0.0.1:#{strict.port} -tls1_2 < /dev/null 2>&1`
check 'min_version 1.3 refuses TLS 1.2', old.include?('alert protocol version') || old.include?('alert number 70')
strict.shutdown(grace: 0.5)

mutual = Kiln::Transport::Tls.new(cert: CERT, key: KEY, ca: CERT, verify: :require)
guarded = Kiln::Server.new(router, nil, log: log, host: '127.0.0.1', port: 0, tls: mutual)
guarded.start
anonymous = `printf 'GET / HTTP/1.1\\r\\nHost: x\\r\\nConnection: close\\r\\n\\r\\n' |
openssl s_client -ign_eof -connect 127.0.0.1:#{guarded.port} 2>&1`
known = `printf 'GET / HTTP/1.1\\r\\nHost: x\\r\\nConnection: close\\r\\n\\r\\n' |
openssl s_client -ign_eof -cert #{CERT} -key #{KEY} -connect 127.0.0.1:#{guarded.port} 2>&1`
check 'verify: :require refuses a client without a certificate', !anonymous.include?('scheme=https')
check 'verify: :require accepts a client certificate signed by the CA', known.include?('scheme=https tls=true')
guarded.shutdown(grace: 0.5)

rejects('a missing certificate fails at start') do
  Kiln::Server.new(router, nil, log: log, port: 0, tls: Kiln::Transport::Tls.new(cert: 'missing.pem', key: KEY)).start
end
rejects('a key that does not match fails at start') do
  Kiln::Server.new(router, nil, log: log, port: 0, tls: Kiln::Transport::Tls.new(cert: CERT, key: CERT)).start
end
rejects('verify needs a CA') { Kiln::Transport::Tls.new(cert: CERT, key: KEY, verify: :require) }
rejects('min_version must be known') { Kiln::Transport::Tls.new(cert: CERT, key: KEY, min_version: '1.0') }
log.close
