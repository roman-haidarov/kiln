require 'socket'

port = Integer(ARGV.fetch(0))
count = Integer(ARGV.fetch(1))
socket = nil
100.times do
  begin
    socket = TCPSocket.new('127.0.0.1', port)
    break
  rescue SystemCallError
    sleep 0.1
  end
end
abort("unable to connect to port #{port}") unless socket

request = "GET /health HTTP/1.1\r\nHost: x\r\n\r\n"
buffer = +''
completed = 0
count.times do
  socket.write(request)
  loop do
    boundary = buffer.index("\r\n\r\n")
    if boundary
      header = buffer.slice!(0, boundary + 4)
      length = Integer(header[/^content-length:\s*(\d+)/i, 1])
      if buffer.bytesize >= length
        buffer.slice!(0, length)
        completed += 1
        break
      end
    end
    buffer << socket.readpartial(65_536)
  end
end
socket.close
puts completed
