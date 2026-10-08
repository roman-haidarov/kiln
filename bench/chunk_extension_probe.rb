require "kiln"
require "socket"

reader, writer = Socket.pair(Socket::AF_UNIX, Socket::SOCK_STREAM, 0)
writer.write("3;\r\nabc\r\n0\r\n\r\n".b)
server = Kiln::Server.new(nil, nil, log: nil, port: 0)
_body, error = server.send(:read_chunked, reader, Kiln::ReadBuffer.new, Kiln.now + 1.0)
reader.close
writer.close
raise 'FAIL invalid extension "3;" -> 400' unless error == :bad
puts 'ok   invalid extension "3;" -> 400'
