require 'kiln'

dir = ENV['KILN_STATIC_DIR'] || '/tmp/kiln-static-bench'
SMALL = File.read(File.join(dir, 'small.txt'))
BLOB = File.read(File.join(dir, 'big.bin'))

router = Kiln::Routing::Router.new
router.get('/files/*path', Kiln::Static.new(dir))
router.get('/memory/small', ->(ctx) { ctx.res.text(SMALL) })
router.get('/memory/big', ->(ctx) { ctx.res.text(BLOB) })
router.seal!
log = Kiln::Observability::Log.new($stdout)
port = (ENV['PORT'] || '18400').to_i
backend = ENV['KILN_BACKEND'] == 'base' ? :base : :event
server = Kiln::Server.new(router, nil, log:, host: '127.0.0.1', port:, backend:)
server.start
loop { Kiln::Runtime.pause(3600) }
