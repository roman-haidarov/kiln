require 'socket'
require 'kiln/db'

Thread.current
Thread.report_on_exception = false

def greeting
  flags = 1 | 512 | 2048 | 32_768 | 524_288
  body = "\x0a8.4.0\x00"
  body += [1].pack('V') + "12345678\x00" + [flags & 65_535].pack('v')
  body += [33, 2, flags >> 16, 21].pack('CvvC') + ("\x00" * 10)
  body += "123456789012\x00mysql_native_password\x00"
  [body.bytesize & 255, (body.bytesize >> 8) & 255, 0, 0].pack('C*') + body
end

server = TCPServer.new('127.0.0.1', 0)
port = server.addr[1]
ready = Queue.new
finish = Queue.new
peer = Thread.new do
  socket = server.accept
  begin
    socket.write(greeting)
    socket.read(36)
    ready << true
    finish.pop
  ensure
    socket.close
  end
end
ticks = 0
running = true
ticker = Thread.new do
  while running
    sleep 0.002
    ticks += 1
  end
end
started = Kiln::DB::Native.now_ms
timed_out = false
begin
  conn = Kiln::DB::Conn.open(Kiln::DB::Native::KIND_MY, '127.0.0.1', port,
                             'kiln', 'password', 'kilndb', 'test/fixtures/tls_cert.pem', 'localhost', timeout: 0.1)
  conn.close
rescue Kiln::DB::Timeout
  timed_out = true
end
elapsed = Kiln::DB::Native.now_ms - started
running = false
ticker.join
finish << true
peer.join
server.close
raise "TLS deadline #{elapsed}" unless timed_out && elapsed < 1000
raise 'TLS blocks the worker' unless ticks >= 3
raise 'TLS handshake not reached' unless ready.pop

puts 'tls handshake deadline ok'
puts 'tls worker progress ok'
