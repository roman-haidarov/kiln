require 'fileutils'
require 'kiln'
require 'socket'
require 'stringio'
require 'test/support'

def check(label, passed)
  raise "FAIL #{label}" unless passed

  puts "ok   #{label}"
end

MODES = { 'event' => [:event, {}], 'lanes' => [:event, { handlers: 2 }], 'base' => [:base, {}] }.freeze
BIG = ('x' * (8 << 20)).freeze

def serve(mode, file)
  backend, extra = MODES.fetch(mode)
  router = Kiln::Routing::Router.new
  router.get('/', ->(ctx) { ctx.res.text('alive') })
  router.get('/big', ->(ctx) { ctx.res.text(BIG) })
  router.get('/stream', lambda { |ctx|
    ctx.res.stream(type: 'text/plain') do |out|
      piece = 'y' * 65_536
      200.times { out << piece }
    end
  })
  router.seal!
  server = Kiln::Server.new(router, nil, log: Kiln::Observability::Log.new(StringIO.new), backend: backend,
                                         host: '127.0.0.1', port: 0, **extra)
  server.start
  File.write("#{file}.part", server.port.to_s)
  File.rename("#{file}.part", file)
  Kernel.sleep 60
  exit 0
end

def reset_after_reply(port, path)
  sock = TCPSocket.new('127.0.0.1', port)
  sock.write("GET #{path} HTTP/1.1\r\nHost: x\r\n\r\n")
  Kernel.sleep 0.05
  sock.close
rescue IOError, SystemCallError
  nil
end

def port_from(file)
  limit = Kiln::Runtime.now + 10
  Kernel.sleep 0.02 until File.exist?(file) || Kiln::Runtime.now >= limit
  File.exist?(file) ? File.read(file).to_i : 0
end

serve(ARGV[1], ARGV[2]) if ARGV[0] == 'serve'

dir = "/tmp/kiln-sigpipe-#{Process.pid}"
Dir.mkdir(dir)
self_path = File.expand_path($PROGRAM_NAME)
children = MODES.keys.map { |mode| [mode, Process.spawn(self_path, 'serve', mode, "#{dir}/#{mode}")] }

children.each do |mode, pid|
  port = port_from("#{dir}/#{mode}")
  check "#{mode}: a server started without SIGPIPE ignored is listening", port.positive?
  4.times do
    reset_after_reply(port, '/big')
    reset_after_reply(port, '/stream')
  end
  Kernel.sleep 0.2
  reply = exchange(port, "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
  check "#{mode}: clients that reset mid-response do not kill the process", reply.end_with?('alive')
  Process.kill('TERM', pid)
  _, status = Process.wait2(pid)
  check "#{mode}: the process was still alive until it was told to stop", status.signaled? && status.termsig == 15
end

children.each { |mode, _pid| FileUtils.rm_f("#{dir}/#{mode}") }
Dir.rmdir(dir)
