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
