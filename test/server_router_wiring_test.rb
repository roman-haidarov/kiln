require 'kiln'
require 'stringio'
require 'test/support'

def need(label, condition)
  raise label unless condition
end

def router_server(mode, router, log)
  case mode
  when :base
    Kiln::Server.new(router, log: log, backend: :base, host: '127.0.0.1')
  when :inline
    Kiln::Server.new(router, log: log, host: '127.0.0.1')
  when :workers
    Kiln::Server.new(router, log: log, handlers: 2, host: '127.0.0.1')
  else
    raise 'unknown router mode'
  end
end

router = Kiln::Routing::Router.new
                              .get('/', ->(ctx) { ctx.res.text('router wired') })
                              .get('/error', ->(_ctx) { raise 'router wiring failure' })
                              .seal!
%i[base inline workers].each do |mode|
  buffer = StringIO.new
  log = Kiln::Observability::Log.new(buffer)
  server = router_server(mode, router, log)
  begin
    server.start
    raw = exchange(server.port, "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", 3)
    need("#{mode} router request", raw.start_with?('HTTP/1.1 200 ') && raw.end_with?('router wired'))
    raw = exchange(server.port, "GET /error HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", 3)
    need("#{mode} router failure", raw.start_with?('HTTP/1.1 500 '))
  ensure
    server.shutdown(grace: 1)
    log.close
  end
  need("#{mode} builtin log", buffer.string.include?('router wiring failure'))
  puts "ok isolated router #{mode}"
end
