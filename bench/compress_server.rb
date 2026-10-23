require 'kiln'

dir = ENV['KILN_COMPRESS_DIR'] || '/tmp/cz'
API = File.read(File.join(dir, 'api.json'))
SMALL = File.read(File.join(dir, 'small.json'))

router = Kiln::Routing::Router.new
router.get('/api', ->(ctx) { ctx.res.json(API) })
router.get('/small', ->(ctx) { ctx.res.json(SMALL) })
router.seal!
level = (ENV['KILN_LEVEL'] || '2').to_i
app = ENV['KILN_GZIP'] == '0' ? router : Kiln::Middleware::Compress.new(router, level:)
log = Kiln::Observability::Log.new($stdout)
port = (ENV['PORT'] || '18500').to_i
server = Kiln::Server.new(app, nil, log:, host: '127.0.0.1', port:)
server.start
loop { Kiln::Runtime.pause(3600) }
