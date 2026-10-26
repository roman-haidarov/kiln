require 'kiln'
require 'socket'
require 'stringio'
require 'test/support'

def check(label, passed)
  raise "FAIL #{label}" unless passed

  puts "ok   #{label}"
end

WS_MASK = 0x37FA213D

def ws_frame(opcode, data, fin: true, masked: true)
  data = data.b
  out = (+'').b
  out << ((fin ? 0x80 : 0) | opcode)
  bit = masked ? 0x80 : 0
  size = data.bytesize
  if size < 126
    out << (bit | size)
  elsif size < 65_536
    out << (bit | 126) << (size >> 8) << (size & 0xFF)
  else
    out << (bit | 127)
    7.downto(0) { |shift| out << ((size >> (shift * 8)) & 0xFF) }
  end
  return out + data unless masked

  out << (WS_MASK >> 24) << ((WS_MASK >> 16) & 0xFF) << ((WS_MASK >> 8) & 0xFF) << (WS_MASK & 0xFF)
  out + (size.zero? ? data : Kiln::HTTP::WsNative.kiln_ws_mask(data, size, WS_MASK))
end

class WsClient
  KEY = 'dGhlIHNhbXBsZSBub25jZQ=='.freeze

  attr_reader :head

  def initialize(io, path, protocols: nil, extra: '', first: ''.b)
    @io = io
    @buf = (+'').b
    request = "GET #{path} HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: keep-alive, Upgrade\r\n" \
              "Sec-WebSocket-Key: #{KEY}\r\nSec-WebSocket-Version: 13\r\n"
    request += "Sec-WebSocket-Protocol: #{protocols}\r\n" if protocols
    @io.write("#{request}#{extra}\r\n#{first}")
    raw = collect_until(@io, 2) { |buf| buf.include?("\r\n\r\n") }
    cut = raw.index("\r\n\r\n")
    @head = cut ? raw.byteslice(0, cut + 4) : raw
    @buf << raw.byteslice(cut + 4, raw.bytesize - cut - 4) if cut
  end

  def send(opcode, data, **opts)
    @io.write(ws_frame(opcode, data, **opts))
  end

  def send_raw(data) = @io.write(data)

  def receive(seconds = 0.5)
    limit = Kiln::Runtime.now + seconds
    loop do
      parsed = parse
      return parsed if parsed
      return nil if Kiln::Runtime.now >= limit

      ready, = IO.select([@io], nil, nil, limit - Kiln::Runtime.now)
      next unless ready

      chunk = begin
        @io.read_nonblock(65_536, exception: false)
      rescue IOError, SystemCallError
        nil
      end
      return nil if chunk.nil?

      @buf << chunk if chunk.is_a?(String)
    end
  end

  def close_code(seconds = 0.5)
    loop do
      got = receive(seconds)
      return -1 if got.nil?
      return got[1].bytesize >= 2 ? (got[1].getbyte(0) << 8) | got[1].getbyte(1) : 1005 if got[0] == 8
    end
  end

  def close = @io.close

  private

  def parse
    return nil if @buf.bytesize < 2

    size = @buf.getbyte(1) & 0x7F
    head = 2
    if size == 126
      return nil if @buf.bytesize < 4

      size = (@buf.getbyte(2) << 8) | @buf.getbyte(3)
      head = 4
    elsif size == 127
      return nil if @buf.bytesize < 10

      size = 0
      8.times { |index| size = (size << 8) | @buf.getbyte(2 + index) }
      head = 10
    end
    return nil if @buf.bytesize < head + size

    opcode = @buf.getbyte(0) & 0x0F
    data = @buf.byteslice(head, size)
    @buf = @buf.byteslice(head + size, @buf.bytesize - head - size)
    [opcode, data]
  end
end

log = Kiln::Observability::Log.new(StringIO.new)
GOT = Queue.new
CLOSE_CHECKS = Queue.new
IDLE = Queue.new
router = Kiln::Routing::Router.new
router.get('/ws', lambda { |ctx|
  ctx.res.websocket(ctx, protocols: %w[chat echo], max_message: 4096) do |ws|
    ws.each do |message|
      if message.text?
        ws.send_text("echo:#{message.data}")
      else
        ws.send_binary(message.data.reverse)
      end
    end
    GOT << (ws.close_code || 0)
  end
})
router.get('/ping', lambda { |ctx|
  ctx.res.websocket(ctx, ping_interval: 0.2) do |ws|
    ws.each { |message| ws.send_text(message.data) }
  end
})
router.get('/mirror', lambda { |ctx|
  ctx.res.websocket(ctx) do |ws|
    ws.each do |message|
      message.text? ? ws.send_text(message.data) : ws.send_binary(message.data)
    end
  end
})
router.get('/close-check', lambda { |ctx|
  ctx.res.websocket(ctx) do |ws|
    invalid_code = false
    invalid_reason = false
    begin
      ws.close(1006)
    rescue ArgumentError
      invalid_code = true
    end
    begin
      ws.close(1000, "\xFF".b)
    rescue ArgumentError
      invalid_reason = true
    end
    ws.close(1000, '🙂' * 31)
    CLOSE_CHECKS << [invalid_code, invalid_reason]
  end
})
router.get('/raw', lambda { |ctx|
  ctx.res.upgrade('kiln-echo') do |conn|
    while (chunk = conn.read)
      next if chunk.empty?

      conn.write(chunk.upcase)
      break if chunk.include?('bye')
    end
  end
})
router.get('/hijack', lambda { |ctx|
  ctx.res.hijack do |conn|
    conn.write("HTTP/1.1 200 OK\r\nContent-Length: 8\r\nConnection: close\r\n\r\nhijacked")
  end
})
router.get('/ws-any', lambda { |ctx|
  ctx.res.websocket(ctx, origins: ['*']) { |ws| ws.each { |message| ws.send_text(message.data) } }
})
router.get('/ws-list', lambda { |ctx|
  ctx.res.websocket(ctx, origins: ['https://App.Example']) { |ws| ws.each { |message| ws.send_text(message.data) } }
})
router.get('/idle-raw', lambda { |ctx|
  ctx.res.upgrade('kiln-idle', idle_timeout: 0.3) do |conn|
    IDLE << (conn.read.nil? ? 'closed' : 'data')
  end
})
router.get('/timed-raw', lambda { |ctx|
  ctx.res.upgrade('kiln-idle', idle_timeout: nil) do |conn|
    IDLE << (conn.read(timeout: 0.2) == '' ? 'empty' : 'other')
    conn.write('still')
  end
})
router.seal!
long = 'w' * 70_000

%i[event base].each do |backend|
  server = Kiln::Server.new(router, log: log, backend: backend, host: '127.0.0.1', port: 0)
  server.start
  port = server.port

  ws = WsClient.new(TCPSocket.new('127.0.0.1', port), '/ws', protocols: 'other, echo')
  valid_handshake = ws.head.start_with?('HTTP/1.1 101 ') &&
                    ws.head.include?('Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=') &&
                    ws.head.include?('Upgrade: websocket') && ws.head.include?('Sec-WebSocket-Protocol: echo')
  check "#{backend}: the handshake answers 101 with the RFC 6455 accept key", valid_handshake
  close_client = WsClient.new(TCPSocket.new('127.0.0.1', port), '/close-check')
  close_frame = close_client.receive
  close_payload = close_frame && close_frame[1]
  close_reason = close_payload&.byteslice(2, close_payload.bytesize - 2)&.force_encoding(Encoding::UTF_8)
  close_client.send(8, close_payload) if close_payload
  close_client.close
  close_check = CLOSE_CHECKS.pop(timeout: 0.7)
  check "#{backend}: close validates code and UTF-8 and truncates on a character boundary",
        close_frame && close_frame[0] == 8 && close_reason&.valid_encoding? && close_reason == '🙂' * 30 &&
        close_reason.bytesize <= 123 && close_check == [true, true]
  mirror = WsClient.new(TCPSocket.new('127.0.0.1', port), '/mirror')
  mirror.send(1, '')
  check "#{backend}: an empty text message has a complete frame", mirror.receive == [1, ''.b]
  mirror.send(2, '')
  check "#{backend}: an empty binary message has a complete frame", mirror.receive == [2, ''.b]
  mirror.send(9, '')
  check "#{backend}: an empty ping receives a complete pong", mirror.receive == [10, ''.b]
  [125, 126, 127, 128, 255, 256, 65_535, 65_536].each do |size|
    data = ('w' * size).b
    [1, 2].each do |opcode|
      mirror.send(opcode, data)
      check "#{backend}: frame opcode #{opcode} length #{size} round-trips", mirror.receive == [opcode, data]
    end
  end
  mirror.send(8, "\x03\xE8".b)
  mirror.close_code
  mirror.close

  short16 = WsClient.new(TCPSocket.new('127.0.0.1', port), '/mirror')
  short16.send_raw("\x81\xFE\x00\x01\x37\xFA\x21\x3D\x4F".b)
  check "#{backend}: a nonminimal 16-bit frame length closes with 1002", short16.close_code == 1002
  short16.close
  short64 = WsClient.new(TCPSocket.new('127.0.0.1', port), '/mirror')
  short64.send_raw("\x81\xFF\x00\x00\x00\x00\x00\x00\x00\x01\x37\xFA\x21\x3D\x4F".b)
  check "#{backend}: a nonminimal 64-bit frame length closes with 1002", short64.close_code == 1002
  short64.close

  foreign = WsClient.new(TCPSocket.new('127.0.0.1', port), '/mirror', extra: "Origin: http://evil.example\r\n")
  foreign.close
  same = WsClient.new(TCPSocket.new('127.0.0.1', port), '/mirror', extra: "Origin: http://x\r\n")
  same.close
  opaque = WsClient.new(TCPSocket.new('127.0.0.1', port), '/mirror', extra: "Origin: null\r\n")
  opaque.close
  check "#{backend}: by default a handshake from another origin gets 403 and the same host gets 101",
        foreign.head.start_with?('HTTP/1.1 403 ') && same.head.start_with?('HTTP/1.1 101 ') &&
        opaque.head.start_with?('HTTP/1.1 403 ')
  terminated = WsClient.new(TCPSocket.new('127.0.0.1', port), '/mirror', extra: "Origin: https://x\r\n")
  terminated.close
  check "#{backend}: an HTTPS page reaching a plain backend through TLS termination gets 101",
        terminated.head.start_with?('HTTP/1.1 101 ')
  anyone = WsClient.new(TCPSocket.new('127.0.0.1', port), '/ws-any', extra: "Origin: http://evil.example\r\n")
  anyone.close
  listed = WsClient.new(TCPSocket.new('127.0.0.1', port), '/ws-list', extra: "Origin: https://app.example\r\n")
  listed.close
  unlisted = WsClient.new(TCPSocket.new('127.0.0.1', port), '/ws-list', extra: "Origin: https://other.example\r\n")
  unlisted.close
  check "#{backend}: origins: accepts '*' and an exact list",
        anyone.head.start_with?('HTTP/1.1 101 ') && listed.head.start_with?('HTTP/1.1 101 ') &&
        unlisted.head.start_with?('HTTP/1.1 403 ')
  ws.send(1, 'hello')
  check "#{backend}: a text message is echoed", ws.receive == [1, 'echo:hello'.b]
  ws.send(2, "\x01\x02\x03".b)
  check "#{backend}: a binary message is echoed", ws.receive == [2, "\x03\x02\x01".b]
  ws.send(1, 'frag', fin: false)
  ws.send(9, 'ping!')
  ws.send(0, 'men', fin: false)
  ws.send(0, 'ted')
  pong = ws.receive
  check "#{backend}: a ping inside a fragmented message is answered first", pong == [10, 'ping!'.b]
  check "#{backend}: fragments are joined into one message", ws.receive == [1, 'echo:fragmented'.b]
  ws.send(8, "\x03\xE8bye".b)
  check "#{backend}: a close frame is answered with the same code", ws.close_code == 1000
  check "#{backend}: the handler sees the client's close code", GOT.pop(timeout: 0.7) == 1000
  ws.close

  peer_client_only = WsClient.new(TCPSocket.new('127.0.0.1', port), '/ws')
  peer_client_only.send(8, "\x03\xF2".b)
  check "#{backend}: client-only close code 1010 is acknowledged as 1000", peer_client_only.close_code == 1000
  check "#{backend}: the handler retains the peer's original close code 1010", GOT.pop(timeout: 0.7) == 1010
  peer_client_only.close

  bad = WsClient.new(TCPSocket.new('127.0.0.1', port), '/ws')
  bad.send(1, 'unmasked', masked: false)
  check "#{backend}: an unmasked client frame closes with 1002", bad.close_code == 1002
  GOT.pop(timeout: 0.7)
  bad.close

  utf = WsClient.new(TCPSocket.new('127.0.0.1', port), '/ws')
  utf.send(1, "\xC3\x28".b)
  check "#{backend}: invalid UTF-8 text closes with 1007", utf.close_code == 1007
  GOT.pop(timeout: 0.7)
  utf.close

  reason = WsClient.new(TCPSocket.new('127.0.0.1', port), '/ws')
  reason.send(8, "\x03\xE8\xC3\x28".b)
  check "#{backend}: a close reason that is not UTF-8 is answered with 1007", reason.close_code == 1007
  GOT.pop(timeout: 0.7)
  reason.close

  huge = WsClient.new(TCPSocket.new('127.0.0.1', port), '/ws')
  huge.send(2, long)
  check "#{backend}: a message over max_message closes with 1009", huge.close_code == 1009
  GOT.pop(timeout: 0.7)
  huge.close

  early = WsClient.new(TCPSocket.new('127.0.0.1', port), '/ws', first: ws_frame(1, 'early'))
  check "#{backend}: a frame sent with the handshake is not lost", early.receive == [1, 'echo:early'.b]
  early.send(8, "\x03\xE8".b)
  early.close_code
  GOT.pop(timeout: 0.7)
  early.close

  pinger = WsClient.new(TCPSocket.new('127.0.0.1', port), '/ping')
  first = pinger.receive(1.0)
  check "#{backend}: ping_interval sends pings", first && first[0] == 9
  silent = pinger.close_code(2.0)
  check "#{backend}: a client that never answers pings is dropped", silent == -1 || silent == 1006 || silent == 1005
  pinger.close

  spoof = WsClient.new(TCPSocket.new('127.0.0.1', port), '/ping')
  ping_frame = spoof.receive(1.0)
  spoof.send(10, 'wrong pong') if ping_frame && ping_frame[0] == 9
  silent = spoof.close_code(2.0)
  check "#{backend}: mismatched PONG does not satisfy heartbeat", ping_frame && ping_frame[0] == 9 &&
                                                                  (silent == -1 || silent == 1006 || silent == 1005)
  spoof.close

  plain = exchange(port, "GET /ws HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
  check "#{backend}: a plain GET to a websocket route gets 426",
        plain.start_with?('HTTP/1.1 426 ') && plain.include?('Sec-WebSocket-Version: 13')
  wrong = exchange(port, "GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
                         "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: short\r\n\r\n")
  check "#{backend}: a malformed key gets 400", wrong.start_with?('HTTP/1.1 400 ')

  raw = TCPSocket.new('127.0.0.1', port)
  raw.write("GET /raw HTTP/1.1\r\nHost: x\r\nUpgrade: kiln-echo\r\nConnection: Upgrade\r\n\r\nhi there")
  answer = collect_until(raw, 2) { |buf| buf.include?('HI THERE') }
  raw.write('bye')
  rest = read_until_closed(raw, 2)
  raw.close
  check "#{backend}: a custom upgrade hands the connection to the handler",
        answer.start_with?('HTTP/1.1 101 Switching Protocols') && answer.include?('Upgrade: kiln-echo') &&
        answer.end_with?('HI THERE') && rest == 'BYE'

  hijacked = exchange(port, "GET /hijack HTTP/1.1\r\nHost: x\r\n\r\n")
  check "#{backend}: hijack writes the raw response",
        hijacked == "HTTP/1.1 200 OK\r\nContent-Length: 8\r\nConnection: close\r\n\r\nhijacked"

  idle = TCPSocket.new('127.0.0.1', port)
  idle.write("GET /idle-raw HTTP/1.1\r\nHost: x\r\nUpgrade: kiln-idle\r\nConnection: Upgrade\r\n\r\n")
  idle_head = collect_until(idle, 2) { |buf| buf.include?("\r\n\r\n") }
  idle_from = Kiln::Runtime.now
  idle_rest = read_until_closed(idle, 3)
  idle_took = Kiln::Runtime.now - idle_from
  idle.close
  check "#{backend}: an idle upgraded connection is closed after idle_timeout",
        idle_head.start_with?('HTTP/1.1 101 ') && IDLE.pop(timeout: 2) == 'closed' &&
        idle_rest.empty? && idle_took < 2.5

  timed = TCPSocket.new('127.0.0.1', port)
  timed.write("GET /timed-raw HTTP/1.1\r\nHost: x\r\nUpgrade: kiln-idle\r\nConnection: Upgrade\r\n\r\n")
  timed_reply = collect_until(timed, 2) { |buf| buf.end_with?('still') }
  timed.close
  check "#{backend}: an explicit read timeout returns an empty chunk and keeps the tunnel open",
        timed_reply.start_with?('HTTP/1.1 101 ') && timed_reply.end_with?('still') && IDLE.pop(timeout: 2) == 'empty'

  open = WsClient.new(TCPSocket.new('127.0.0.1', port), '/ws')
  open.send(1, 'still here')
  open.receive
  stopper = Thread.new { server.shutdown(grace: 2.0) }
  code = open.close_code(3.0)
  stopper.join
  open.close
  GOT.clear
  check "#{backend}: shutdown closes open websockets", backend == :base ? code == -1 || code == 1001 : code == 1001
end

response = Kiln::Testing.call(router, 'GET', '/ws', headers: {
                                'Upgrade' => 'websocket', 'Connection' => 'Upgrade', 'Sec-WebSocket-Version' => '13',
                                'Sec-WebSocket-Key' => WsClient::KEY
                              })
check 'Testing.call reports the 101 of a websocket route', response.status == 101 && response.tunnel?
log.close
