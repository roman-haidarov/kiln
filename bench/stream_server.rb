require 'kiln'

CHUNK = 'z' * 65_536
BLOB = CHUNK * 1024

router = Kiln::Routing::Router.new
router.get('/health', ->(ctx) { ctx.res.text("ok\n") })
if ENV['KILN_STREAM'] == '1'
  router.get('/stream', lambda do |ctx|
    ctx.res.stream do |out|
      1024.times { out.write(CHUNK) }
    end
  end)
end
router.get('/blob', ->(ctx) { ctx.res.text(BLOB) })
router.seal!
log = Kiln::Observability::Log.new($stdout)
port = (ENV['PORT'] || '18200').to_i
backend = ENV['KILN_BACKEND'] == 'base' ? :base : :event
server = Kiln::Server.new(router, log:, host: '127.0.0.1', port:, backend:)
server.start
loop { Kiln::Runtime.pause(3600) }
