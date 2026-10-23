require 'kiln'
require 'bench/modes'

router = Kiln::Routing::Router.new
                              .get('/users/:name', lambda { |ctx|
                                user = { 'name' => ctx.req.params['name'], 'age' => 18, 'balance' => 2000.50 }
                                ctx.res.json_value(user)
                              })
                              .seal!
log = Kiln::Observability::Log.new($stdout)
port = (ENV['PORT'] || '18100').to_i
mode = ENV['KILN_MODE'] || 'server'
worker_count = ENV['SPINEL_WORKERS'] || '1'
cpu_count = (ENV['KILN_CPUS'] || worker_count).to_i
shard_count = cpu_count < 1 ? 1 : cpu_count
server = kiln_mode_server(mode, router, log, port, shard_count: shard_count)
server.start
loop { Kiln::Runtime.pause(3600) }
