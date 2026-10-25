require 'kiln'
require 'tmpdir'
require 'fileutils'
require 'stringio'
require 'test/support'

WIRED_MESSAGE = 'wired app'

class WiringHandler
  def call(ctx)
    ctx.res.text(WIRED_MESSAGE)
  end
end

class WiringFailure
  def call(_ctx)
    raise 'wiring failure'
  end
end

def need(label, condition)
  raise label unless condition
end

def wired_server(mode, handler, log)
  options = { log: log, host: '127.0.0.1', port: 0 }
  case mode
  when :facade_base
    Kiln::Server.new(handler, backend: :base, **options)
  when :facade_inline
    Kiln::Server.new(handler, **options)
  when :facade_workers
    Kiln::Server.new(handler, handlers: 2, **options)
  when :direct_base
    Kiln::Server::Base.new(handler, **options)
  when :direct_inline
    Kiln::Server::Event.new(handler, **options)
  when :direct_workers
    Kiln::Server::Event.new(handler, handlers: 2, **options)
  else
    raise 'unknown wiring mode'
  end
end

def wired_request(mode, handler, log, expected)
  server = wired_server(mode, handler, log)
  server.start
  raw = exchange(server.port, "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", 3)
  need("#{mode} #{expected}", raw.start_with?('HTTP/1.1 200 ') && raw.end_with?(expected))
ensure
  server&.shutdown(grace: 1)
end

def wired_failure(mode)
  buffer = StringIO.new
  log = Kiln::Observability::Log.new(buffer)
  server = wired_server(mode, WiringFailure.new, log)
  server.start
  raw = exchange(server.port, "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", 3)
  need("#{mode} error response", raw.start_with?('HTTP/1.1 500 '))
ensure
  server&.shutdown(grace: 1)
  log&.close
  need("#{mode} error logger", buffer.string.include?('wiring failure'))
end

def wired_signal
  buffer = StringIO.new
  log = Kiln::Observability::Log.new(buffer)
  server = wired_server(:facade_base, WiringHandler.new, log)
  signaler = Thread.new do
    wait_for { server.port.positive? }
    Process.kill('USR2', Process.pid)
  end
  need('signal shutdown', server.run(grace: 1, signals: ['USR2']).zero?)
  signaler.join
ensure
  signaler&.kill if signaler&.alive?
  server&.shutdown(grace: 1)
  log&.close
  need('signal info logged', buffer.string.include?('SIGUSR2 received'))
end

root = Dir.mktmpdir('kiln-wiring')
begin
  File.write(File.join(root, 'index.html'), 'wired static')
  log = Kiln::Observability::Log.new(StringIO.new)
  callback = ->(ctx) { ctx.res.text(WIRED_MESSAGE) }
  router = Kiln::Routing::Router.new.get('/', callback).seal!
  files = Kiln::Static.new(root)
  object = WiringHandler.new
  bound = object.method(:call)
  %i[facade_base facade_inline facade_workers direct_base direct_inline direct_workers].each do |mode|
    wired_request(mode, callback, log, 'wired app')
    wired_request(mode, router, log, 'wired app')
    wired_request(mode, object, log, 'wired app')
    wired_request(mode, bound, log, 'wired app')
    wired_request(mode, files, log, 'wired static')
    wired_failure(mode)
    puts "ok wiring #{mode}"
  end
  wired_signal
  log.close
  puts 'ok signal logger'
ensure
  FileUtils.remove_entry(root)
end

%i[event base].each do |backend|
  invalid = [{ max_conns: '12' }, { max_conns: 1.5 }, { max_body: 'bad' }, { buffer_body: -1 },
             { read_timeout: '5' }, { header_timeout: 0 }, { request_timeout: Float::NAN },
             { write_timeout: Float::INFINITY }, { keep_alive_timeout: -1 }, { port: 65_536 },
             { max_body: 1, buffer_body: 2 }, { backlog: 0 }, { max_connection_rate: 0.5 },
             { unexpected: true }, { log: Object.new }]
  invalid.each do |options|
    rejected = false
    begin
      Kiln::Server.new(nil, log: nil, backend: backend, **options)
    rescue ArgumentError => error
      rejected = options.keys.any? { |key| error.message.include?(key.to_s) }
    end
    need("#{backend} rejected #{options}", rejected)
  end
  puts "ok strict options #{backend}"
end
