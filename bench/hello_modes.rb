require 'kiln'
require 'bench/modes'

router = Kiln::Router.new
                     .get('/', ->(ctx) { ctx.res.text("Hello, World!\n") })
                     .seal!
log = Kiln::Log.new($stdout)
port = (ENV['PORT'] || '18100').to_i
mode = ENV['KILN_MODE'] || 'server'
worker_count = ENV['SPINEL_WORKERS'] || '1'
cpu_count = (ENV['KILN_CPUS'] || worker_count).to_i
shard_count = cpu_count < 1 ? 1 : cpu_count
server = kiln_mode_server(mode, router, log, port, shard_count: shard_count)
server.start
loop { Kiln.pause(3600) }
