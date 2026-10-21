require 'kiln'
require 'bench/modes'

router = Kiln::Routing::Router.new
                              .get('/', ->(ctx) { ctx.res.text(1000.times.map { 'hello world' }.join) })
                              .seal!
log = Kiln::Observability::Log.new($stdout)
port = (ENV['PORT'] || '18100').to_i
mode = ENV['KILN_MODE'] || 'server'
worker_count = ENV['SPINEL_WORKERS'] || '1'
cpu_count = (ENV['KILN_CPUS'] || worker_count).to_i
lane_count = (cpu_count + 1) / 2
lane_count = 1 if lane_count < 1
shard_count = cpu_count < 1 ? 1 : cpu_count
server = kiln_mode_server(mode, router, log, port, lane_count: lane_count, shard_count: shard_count)
server.start
loop { Kiln::Runtime.pause(3600) }
