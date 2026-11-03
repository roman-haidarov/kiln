require 'kiln'
require 'tmpdir'
require 'test/support'

def check(label, passed)
  raise "FAIL #{label}" unless passed

  puts "ok   #{label}"
end

def fd_count
  File.directory?('/proc/self/fd') ? Dir.children('/proc/self/fd').size : -1
end

def status_of(head) = head.byteslice(9, 3).to_s

def get_status(port, path, verb = 'GET', retain = false)
  sock = TCPSocket.new('127.0.0.1', port)
  sock.write("#{verb} #{path} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
  status = status_of(read_head(sock, 2.0)[0])
  return [sock, status] if retain

  sock.close
  status
end

root = Dir.mktmpdir('kiln-release')
File.write(File.join(root, 'big.bin'), 'b' * (600 * 1024))
gate = Queue.new
router = Kiln::Routing::Router.new
router.get('/hold', lambda { |ctx|
  ctx.res.stream do |out|
    out.write('x')
    out.flush
    gate.pop(timeout: 5)
  end
})
router.get('/f/*path', Kiln::Static.new(root))
router.seal!

server = Kiln::Server.new(router, host: '127.0.0.1', port: 0, max_streams: 1, handlers: 4)
server.start
port = server.port

statuses = Queue.new
racers = Array.new(8) { Thread.new { statuses << get_status(port, '/hold', 'GET', true) } }
racers.each(&:join)
taken = 0
holding = nil
8.times do
  sock, status = statuses.pop
  if status == '200'
    holding = sock
    taken += 1
  else
    sock.close
  end
end
check 'concurrent streams never exceed max_streams', taken == 1

warm = get_status(port, '/f/big.bin')
before = fd_count
refused = 0
60.times { refused += 1 if get_status(port, '/f/big.bin') == '503' }
heads = 0
20.times { heads += 1 if get_status(port, '/f/big.bin', 'HEAD') == '200' }
Kernel.sleep 0.2
after = fd_count
check 'a refused static stream closes its file without GC',
      warm == '503' && refused == 60 && heads == 20 && (before.negative? || after <= before + 4)

gate << true
Kernel.sleep 0.3
check 'the stream slot is given back', get_status(port, '/f/big.bin') == '200'
server.shutdown(grace: 0.5)
holding&.close

capped = Kiln::Server.new(->(ctx) { ctx.res.text('ok') }, host: '127.0.0.1', port: 0, max_conns: 1)
capped.start
keep = TCPSocket.new('127.0.0.1', capped.port)
keep.write("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
served = status_of(read_head(keep, 2.0)[0]) == '200'
extra = Array.new(80) { TCPSocket.new('127.0.0.1', capped.port) }
Kernel.sleep 0.3
held = capped.connections
dropped = 0
capped.loop_stats.each { |row| dropped += row[4] }
bound = 1 + 16 + capped.loops
check 'refused connections stay within max_conns plus the refusal reserve',
      served && held <= bound && dropped.positive?
check 'max_conns counts admitted connections separately from refusals', capped.admitted == 1
refusing = capped.loop_stats.sum { |row| row[5] }
admitted = capped.loop_stats.sum { |row| row[6] }
check 'loop statistics expose local refusing and admitted gauges', refusing <= 16 && admitted == 1
extra.each(&:close)
keep.write("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
check 'the admitted connection keeps working', status_of(read_head(keep, 2.0)[0]) == '200'
keep.close
capped.shutdown(grace: 0.5)
