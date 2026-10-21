require 'fileutils'
require 'kiln'
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

def over_unix(path, data)
  exchange_on(UNIXSocket.new(path), data)
end

REQUEST = "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".freeze
log = Kiln::Observability::Log.new(StringIO.new)
router = Kiln::Routing::Router.new
router.get('/', ->(ctx) { ctx.res.text("#{ctx.req.scheme} ok") })
router.seal!
path = "/tmp/kiln-listen-#{Process.pid}.sock"
FileUtils.rm_f(path)

%i[event base].each do |backend|
  listen = [Kiln::Transport::Listen.tcp('127.0.0.1', 0), Kiln::Transport::Listen.unix(path, mode: 0o660)]
  server = Kiln::Server.new(router, nil, log: log, backend: backend, listen: listen, backlog: 64, tcp_nodelay: false)
  server.start
  tcp_reply = exchange(server.port, REQUEST)
  unix_reply = over_unix(path, REQUEST)
  check "#{backend}: one server answers on TCP and on a unix socket",
        tcp_reply.end_with?('http ok') && unix_reply.end_with?('http ok') && server.ports.size == 2 &&
        server.ports[1].zero?
  check "#{backend}: the unix socket gets the requested mode", (File.stat(path).mode & 0o777) == 0o660
  server.shutdown(grace: 0.5)
  check "#{backend}: shutdown removes the unix socket file", !File.exist?(path)
end

fd = Kiln::Transport::Listen.tcp('127.0.0.1', 0).open(16, false)
inherited_port = Kiln::Transport::Sock.kiln_sock_port(fd)
adopted = Kiln::Server.new(router, nil, log: log, listen: [Kiln::Transport::Listen.fd(fd)])
adopted.start
check 'event: a listening descriptor handed over is served', adopted.port == inherited_port &&
                                                             exchange(inherited_port, REQUEST).end_with?('http ok')
adopted.shutdown(grace: 0.5)

base_fd = Kiln::Transport::Listen.tcp('127.0.0.1', 0).open(16, false)
base_port = Kiln::Transport::Sock.kiln_sock_port(base_fd)
base_adopted = Kiln::Server.new(router, nil, log: log, backend: :base, listen: ["fd:#{base_fd}"])
base_adopted.start
check 'base: a listening descriptor named as fd:N is served', exchange(base_port, REQUEST).end_with?('http ok')
base_adopted.shutdown(grace: 0.5)

parsed = Kiln::Server.new(router, nil, log: log, listen: ['127.0.0.1:0', "unix:#{path}"])
parsed.start
check 'listen strings name TCP and unix addresses', exchange(parsed.port, REQUEST).end_with?('http ok') &&
                                                    over_unix(path, REQUEST).end_with?('http ok')
parsed.shutdown(grace: 0.5)

stale = UNIXServer.new(path)
stale.close
check 'a stale unix socket file is left behind by a dead server', File.exist?(path)
replaced = Kiln::Server.new(router, nil, log: log, listen: ["unix:#{path}"])
replaced.start
check 'a stale unix socket file is replaced', over_unix(path, REQUEST).end_with?('http ok')
rejects('a unix socket that still accepts is not taken over') do
  Kiln::Server.new(router, nil, log: log, backend: :base, listen: ["unix:#{path}"]).start
end
replaced.shutdown(grace: 0.5)

%i[event base].each do |backend|
  owner = Kiln::Server.new(router, nil, log: log, backend: backend, listen: ["unix:#{path}"])
  owner.start
  File.delete(path)
  successor = UNIXServer.new(path)
  owner.shutdown(grace: 0.5)
  check "#{backend}: shutdown does not unlink a replacement unix socket", File.exist?(path)
  successor.close
  File.delete(path)
end

shared = Kiln::Transport::Listen.tcp('127.0.0.1', 0).open(16, true)
shared_port = Kiln::Transport::Sock.kiln_sock_port(shared)
first = Kiln::Server.new(router, nil, log: log, port: shared_port, host: '127.0.0.1', reuse_port: true)
second = Kiln::Server.new(router, nil, log: log, backend: :base, port: shared_port, host: '127.0.0.1',
                                       reuse_port: true)
first.start
second.start
Kiln::Transport::Sock.kiln_sock_close(shared)
answers = Array.new(6) { exchange(shared_port, REQUEST).end_with?('http ok') }
check 'reuse_port lets two servers bind one port', answers.all?
first.shutdown(grace: 0.5)
second.shutdown(grace: 0.5)

busy = Kiln::Server.new(router, nil, log: log, host: '127.0.0.1', port: 0)
busy.start
rejects('a second listener on a taken port reports the address') do
  Kiln::Server.new(router, nil, log: log, backend: :base, host: '127.0.0.1', port: busy.port).start
end
busy.shutdown(grace: 0.5)

rejects('reuse_port cannot use an ephemeral port') do
  Kiln::Server.new(router, nil, log: log, port: 0, reuse_port: true)
end
rejects('base also refuses ephemeral reuse_port') do
  Kiln::Server.new(router, nil, log: log, backend: :base, port: 0, reuse_port: true)
end
rejects('workers option is no longer available') do
  Kiln::Server.new(router, nil, log: log, workers: 2)
end
rejects('buffer_body cannot exceed max_body on event') do
  Kiln::Server.new(router, nil, log: log, max_body: 1024, buffer_body: 4096)
end
rejects('buffer_body cannot exceed max_body on base') do
  Kiln::Server.new(router, nil, log: log, backend: :base, max_body: 1024, buffer_body: 4096)
end
check 'Transport::Listen.systemd is empty without LISTEN_FDS', Kiln::Transport::Listen.systemd.empty?
check 'Transport::Listen.parse reads an IPv6 address', Kiln::Transport::Listen.parse('[::1]:8080').host == '::1'
rejects('listen needs a port') { Kiln::Transport::Listen.parse('localhost') }
rejects('backlog must be positive') { Kiln::Server.new(router, nil, log: log, port: 0, backlog: 0) }
rejects('max_connection_rate must not be negative') do
  Kiln::Server.new(router, nil, log: log, port: 0, max_connection_rate: -1)
end
rejects('base refuses TLS') do
  tls = Kiln::Transport::Tls.new(cert: 'test/fixtures/tls_cert.pem', key: 'test/fixtures/tls_key.pem')
  Kiln::Server.new(router, nil, log: log, backend: :base, port: 0, tls: tls)
end
rejects('TLS refuses unsupported h2 ALPN') do
  Kiln::Transport::Tls.new(cert: 'test/fixtures/tls_cert.pem', key: 'test/fixtures/tls_key.pem', alpn: ['h2'])
end
rejects('TLS refuses mixed supported and unsupported ALPN') do
  Kiln::Transport::Tls.new(cert: 'test/fixtures/tls_cert.pem', key: 'test/fixtures/tls_key.pem',
                           alpn: ['http/1.1', 'h2'])
end
check 'TLS accepts HTTP/1.1 ALPN',
      Kiln::Transport::Tls.new(cert: 'test/fixtures/tls_cert.pem',
                               key: 'test/fixtures/tls_key.pem').alpn == ['http/1.1']
rejects('TLS refuses empty ALPN') do
  Kiln::Transport::Tls.new(cert: 'test/fixtures/tls_cert.pem', key: 'test/fixtures/tls_key.pem', alpn: [])
end
custom_alpn = ['http/1.1']
frozen_tls = Kiln::Transport::Tls.new(cert: 'test/fixtures/tls_cert.pem', key: 'test/fixtures/tls_key.pem',
                                      alpn: custom_alpn)
custom_alpn[0] = 'h2'
check 'TLS ALPN is independent of the caller array', frozen_tls.alpn == ['http/1.1']
check 'TLS ALPN and the default protocol string cannot be mutated',
      frozen_tls.alpn.frozen? && frozen_tls.alpn[0].frozen? && Kiln::Transport::Tls::DEFAULT_ALPN[0].frozen?
log.close
