require 'kiln'
require 'bench/modes'

TEXT = ('kiln-regression-text ' * 128).freeze
ITEMS = Array.new(64) { |index| { 'id' => index, 'name' => "kiln-regression-item-#{index}" } }.freeze
stream_response = ->(ctx) { ctx.res.stream(type: 'text/plain', length: TEXT.bytesize) { |out| out.write(TEXT) } }

router = Kiln::Routing::Router.new
router.get('/health', ->(ctx) { ctx.res.text("ok\n") })
router.get('/text', ->(ctx) { ctx.res.text(TEXT) })
router.get('/json', ->(ctx) { ctx.res.json_value({ 'items' => ITEMS }) })
router.get('/stream', stream_response)
router.get('/gzip', ->(ctx) { ctx.res.text(TEXT) })
router.get('/gzip-stream', stream_response)
app = Kiln::Middleware::Compress.new(router.seal!, min_size: 64)
log = Kiln::Observability::Log.new($stdout)
port = (ENV['PORT'] || '18421').to_i
mode = ENV['KILN_MODE'] || 'inline'
workers = (ENV['SPINEL_WORKERS'] || '1').to_i
server = kiln_mode_server(mode, app, log, port, shard_count: [workers, 1].max)
server.start
loop { Kiln::Runtime.pause(3600) }
