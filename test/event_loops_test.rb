require 'kiln'
require 'test/support'

REQUEST = "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n".freeze

def need(label, condition)
  raise label unless condition
end

def fd_count
  File.directory?('/proc/self/fd') ? Dir.children('/proc/self/fd').size : -1
end

left = Kiln::Server::Event.new(->(ctx) { ctx.res.text('left') }, port: 0)
right = Kiln::Server::Event.new(->(ctx) { ctx.res.text('right') }, port: 0)
begin
  left.start
  right.start
  need('loop separation', exchange(left.port, REQUEST).end_with?('left') &&
                          exchange(right.port, REQUEST).end_with?('right'))
  left.shutdown(grace: 0.5)
  need('stop one loop only', exchange(right.port, REQUEST).end_with?('right'))
  puts 'ok independent event loops and shutdown'
ensure
  left.shutdown(grace: 0)
  right.shutdown(grace: 0)
end

seen = Queue.new
handler = ->(ctx) { seen << ctx.id; ctx.res.text('ok') }
server = Kiln::Server.new(handler, host: '127.0.0.1', port: 0)
server.start
begin
  need('loop count follows worker budget', server.loops == Kiln::Runtime.workers)
  clients = Array.new(64) do
    Thread.new { need('group response', exchange(server.port, REQUEST).end_with?('ok')) }
  end
  clients.each(&:join)
  ids = Array.new(64) { seen.pop }
  need('request IDs must be unique across loops', ids.uniq.size == 64)
  puts 'ok facade loops and unique request IDs'
ensure
  server.shutdown(grace: 0.5)
end

baseline = fd_count
12.times do
  server = Kiln::Server.new(->(ctx) { ctx.res.text('ok') }, host: '127.0.0.1', port: 0)
  server.start
  need('repeated request', exchange(server.port, REQUEST).end_with?('ok'))
  need('clean stop', server.shutdown(grace: 0.5).zero?)
end
last = fd_count
need('event loop descriptors leaked', baseline < 0 || last <= baseline + Kiln::Runtime.workers)
puts 'ok repeated start and stop release descriptors'

restarted = Kiln::Server.new(->(ctx) { ctx.res.text('restart') }, host: '127.0.0.1', port: 0)
2.times do
  restarted.start
  need('same server restart', exchange(restarted.port, REQUEST).end_with?('restart'))
  restarted.shutdown(grace: 0.5)
end
puts 'ok restart the same facade server'


gate = Queue.new
ready = Queue.new
calls = Queue.new
gated = Kiln::Server::Event.new(->(ctx) { calls << true; ctx.res.text('gated') }, port: 0)
gated.start(gate: gate, ready: ready)
need('gated pump starts', ready.pop(timeout: 3))
client = TCPSocket.new('127.0.0.1', gated.port)
client.write(REQUEST)
Kernel.sleep 0.02
need('pump served before the startup gate opened', calls.empty?)
gate.close
reply = exchange_on(client, '')
need('gated response', reply.end_with?('gated'))
gated.shutdown(grace: 0.5)
puts 'ok all pumps wait for the startup barrier'

fd = Kiln::Transport::Listen.tcp('127.0.0.1', 0).open(16, false)
port = Kiln::Transport::Sock.kiln_sock_port(fd)
inherited = Kiln::Server.new(->(ctx) { ctx.res.text('inherited') }, listen: [Kiln::Transport::Listen.fd(fd)])
inherited.start
need('inherited listener response', exchange(port, REQUEST).end_with?('inherited'))
inherited.shutdown(grace: 0.5)
need('caller descriptor was closed', Kiln::Transport::Sock.kiln_sock_kind(fd).positive? &&
                                    Kiln::Transport::Sock.kiln_sock_port(fd) == port)
Kiln::Transport::Sock.kiln_sock_close(fd)
puts 'ok inherited listener stays owned by its caller'

KEEP = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n".freeze
limited = Kiln::Server.new(->(ctx) { ctx.res.text('ok') }, host: '127.0.0.1', port: 0, max_conns: 8)
limited.start
begin
  held = Array.new(8) { TCPSocket.new('127.0.0.1', limited.port) }
  heads = held.map do |sock|
    sock.write(KEEP)
    read_head(sock, 2.0)[0]
  end
  need('max_conns admits its full budget across loops', heads.all? { |head| head.start_with?('HTTP/1.1 200') })
  extra = TCPSocket.new('127.0.0.1', limited.port)
  extra.write(KEEP)
  need('max_conns refuses past the process-wide budget', read_head(extra, 2.0)[0].start_with?('HTTP/1.1 503'))
  extra.close
  held.each(&:close)
  puts 'ok max_conns is shared by all loops'
ensure
  limited.shutdown(grace: 0.5)
end

release = Queue.new
slow_handler = lambda do |ctx|
  release.pop(timeout: 3)
  ctx.res.text('slow')
end
draining = Kiln::Server.new(slow_handler, host: '127.0.0.1', port: 0, handlers: 2)
draining.start
slow = TCPSocket.new('127.0.0.1', draining.port)
slow.write(REQUEST)
Kernel.sleep 0.1
stopper = Thread.new { draining.shutdown(grace: 3) }
Kernel.sleep 0.2
refused = begin
  late = TCPSocket.new('127.0.0.1', draining.port)
  late.close
  false
rescue SystemCallError
  true
end
release << true
stopper.join
slow.close
need('a draining server refuses new connections', refused)
puts 'ok draining loops refuse new connections'
