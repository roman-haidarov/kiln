require 'kiln'
require 'json'
require 'stringio'

server = Kiln::Server::Base.new(nil, log: Kiln::Observability::Log.new(StringIO.new), port: 0)
reader, writer = Socket.pair(Socket::AF_UNIX, Socket::SOCK_STREAM, 0)
writer.shutdown(Socket::SHUT_WR)
scan = Kiln::HTTP::Native.scratch
$stdin.each_line do |line|
  buf = Kiln::HTTP::ReadBuffer.new
  buf.append([line.strip].pack('H*'))
  results = []
  until buf.empty?
    before = buf.size
    message = server.send(:read_request, reader, buf, scan)
    break unless message

    if message[0] == :error
      results << { 'status' => message[1] }
      break
    end
    req = message[1]
    results << { 'status' => 200, 'method' => req.verb, 'path' => req.path.unpack1('H*'),
                 'query' => req.query.unpack1('H*'), 'host' => req.header('host')&.unpack1('H*'),
                 'body' => req.body.unpack1('H*'), 'used' => before - buf.size }
  end
  puts JSON.generate(results)
end
reader.close
writer.close
