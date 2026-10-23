require 'kiln'
require 'json'
require 'stringio'

class StressHandler
  def initialize
    @pool = Kiln::Runtime::Pool.new(16) { Object.new }
    @cpu = Kiln::Runtime::CpuPool.new(2, queue: 8)
  end

  def call(ctx)
    case ctx.req.path
    when '/hang'
      @pool.with { |_resource| Kernel.sleep 5 }
      ctx.res.text('late')
    when '/cpu'
      @cpu.run(timeout: 1) do
        due = Kiln::Runtime.now + 0.04
        value = 0
        while Kiln::Runtime.now < due
          1000.times { value = (value + 1) & 65_535 }
        end
        value
      end
      ctx.res.text('cpu')
    when '/big'
      ctx.res.text('b' * 4_000_000)
    else
      ctx.res.text('ok')
    end
  end

  attr_reader :pool, :cpu
end

handler = StressHandler.new
log = Kiln::Observability::Log.new(StringIO.new)
router = Kiln::Routing::Router.new
%w[/health /hang /cpu /big].each { |path| router.get(path, handler) }
router.seal!
server = Kiln::Server::Base.new(router, nil, log: log, port: 0, host: '127.0.0.1',
                                             max_conns: Integer(ENV.fetch('MAX_CONNS') { '10000' }),
                                             read_timeout: Float(ENV.fetch('READ_TIMEOUT') { '60' }),
                                             request_timeout: Float(ENV.fetch('REQUEST_TIMEOUT') { '0.4' }),
                                             kill_grace: 0.1, write_timeout: 0.3)
server.start
puts JSON.generate({ 'port' => server.port, 'proc_pid' => File.readlink('/proc/self').to_i })
$stdout.flush
$stdin.each_line do |line|
  if line.strip == 'stop'
    server.shutdown(grace: 0.1)
    handler.cpu.shutdown(grace: 0.1)
    puts JSON.generate({ 'connections' => server.connections, 'free' => server.free_slots,
                         'handling' => server.handling,
                         'in_flight' => server.in_flight, 'pool_available' => handler.pool.available,
                         'pool_consistent' => handler.pool.consistent?, 'cpu_alive' => handler.cpu.alive_workers })
    $stdout.flush
    break
  end
  puts JSON.generate({ 'connections' => server.connections, 'free' => server.free_slots, 'handling' => server.handling,
                       'in_flight' => server.in_flight, 'killed' => server.killed, 'late' => server.late,
                       'pool_available' => handler.pool.available, 'pool_out' => handler.pool.checked_out,
                       'pool_consistent' => handler.pool.consistent?, 'cpu_alive' => handler.cpu.alive_workers,
                       'cpu_busy' => handler.cpu.busy, 'cpu_queued' => handler.cpu.queued })
  $stdout.flush
end
log.close
