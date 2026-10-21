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

  def receive(seconds = 2.0)
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

  def close_code(seconds = 2.0)
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
router.seal!
long = 'w' * 70_000

%i[event base].each do |backend|
  server = Kiln::Server.new(router, nil, log: log, backend: backend, host: '127.0.0.1', port: 0)
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
  close_check = CLOSE_CHECKS.pop(timeout: 2)
  check "#{backend}: close validates code and UTF-8 and truncates on a character boundary",
        close_frame && close_frame[0] == 8 && close_reason&.valid_encoding? && close_reason == '🙂' * 30 &&
        close_reason.bytesize <= 123 && close_check == [true, true]
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
  check "#{backend}: the handler sees the client's close code", GOT.pop(timeout: 2) == 1000
  ws.close

  peer_client_only = WsClient.new(TCPSocket.new('127.0.0.1', port), '/ws')
  peer_client_only.send(8, "\x03\xF2".b)
  check "#{backend}: client-only close code 1010 is acknowledged as 1000", peer_client_only.close_code == 1000
  check "#{backend}: the handler retains the peer's original close code 1010", GOT.pop(timeout: 2) == 1010
  peer_client_only.close

  bad = WsClient.new(TCPSocket.new('127.0.0.1', port), '/ws')
  bad.send(1, 'unmasked', masked: false)
  check "#{backend}: an unmasked client frame closes with 1002", bad.close_code == 1002
  GOT.pop(timeout: 2)
  bad.close

  utf = WsClient.new(TCPSocket.new('127.0.0.1', port), '/ws')
  utf.send(1, "\xC3\x28".b)
  check "#{backend}: invalid UTF-8 text closes with 1007", utf.close_code == 1007
  GOT.pop(timeout: 2)
  utf.close

  reason = WsClient.new(TCPSocket.new('127.0.0.1', port), '/ws')
  reason.send(8, "\x03\xE8\xC3\x28".b)
  check "#{backend}: a close reason that is not UTF-8 is answered with 1007", reason.close_code == 1007
  GOT.pop(timeout: 2)
  reason.close

  huge = WsClient.new(TCPSocket.new('127.0.0.1', port), '/ws')
  huge.send(2, long)
  check "#{backend}: a message over max_message closes with 1009", huge.close_code == 1009
  GOT.pop(timeout: 2)
  huge.close

  early = WsClient.new(TCPSocket.new('127.0.0.1', port), '/ws', first: ws_frame(1, 'early'))
  check "#{backend}: a frame sent with the handshake is not lost", early.receive == [1, 'echo:early'.b]
  early.send(8, "\x03\xE8".b)
  early.close_code
  GOT.pop(timeout: 2)
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
