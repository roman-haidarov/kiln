require 'kiln'
require 'kiln/db'

module ScalingWork
  class << self
    def open_conn
      kind = ENV.fetch('DB_KIND', 'pg') == 'pg' ? Kiln::DB::Native::KIND_PG : Kiln::DB::Native::KIND_MY
      Kiln::DB::Conn.open(kind, ENV.fetch('DB_HOST', '127.0.0.1'), ENV.fetch('DB_PORT', '5432').to_i,
                         ENV.fetch('DB_USER', 'bench'), ENV.fetch('DB_PASSWORD', ''), ENV.fetch('DB_NAME', 'bench'),
                         ENV.fetch('DB_CA', ''), ENV.fetch('DB_TLS_NAME', 'localhost'),
                         tls: ENV.fetch('DB_TLS', 'verify_full').to_sym)
    end

    def cpu(seed)
      value = seed
      index = 0
      while index < 30_000
        value = ((value * 1_664_525) + 1_013_904_223) & 0x7fffffff
        index += 1
      end
      value
    end

    def lookup
      id = rand(100_000) + 1
      sql = ENV.fetch('DB_KIND', 'pg') == 'pg' ? 'SELECT name FROM kiln_rps WHERE id = $1' :
                                             'SELECT name FROM kiln_rps WHERE id = ?'
      Kiln::DB::Scope.lease do |conn|
        rows = conn.exec(sql, [id])
        raise 'incorrect database response' unless rows.size == 1 && rows[0][0] == 'kiln'
      end
    end
  end
end

mode = ENV.fetch('KILN_MODE', 'lanes')
pool = if ENV['POOL_SIZE']
         Kiln::DB::Pool.new(Integer(ENV.fetch('POOL_SIZE'))) { ScalingWork.open_conn }
       else
         Kiln::DB::Pool.new { ScalingWork.open_conn }
       end
Kiln::DB::Scope.pool = pool
router = Kiln::Routing::Router.new
router.get('/health', ->(ctx) { ctx.res.text('ok') })
router.get('/hello', ->(ctx) { ctx.res.text('ok') })
router.get('/cpu', ->(ctx) { ctx.res.text("#{ctx.id} #{ScalingWork.cpu(ctx.id)}") })
router.get('/io', ->(ctx) { Kiln::Runtime.pause(0.002); ctx.res.text('ok') })
router.get('/db', ->(ctx) { ScalingWork.lookup; ctx.res.text('ok') })
router.seal!
options = { host: '127.0.0.1', port: Integer(ENV.fetch('PORT', '18421')) }
options[:backend] = :base if mode == 'base'
options[:handlers] = 0 if mode == 'inline'
options[:handlers] = Integer(ENV.fetch('HANDLERS')) if ENV['HANDLERS'] && mode != 'base'
server = Kiln::Server.new(router, **options)
report = Thread.new do
  Kernel.sleep 0.001 until !server.ports.empty?
  pid = File.file?('/proc/self/stat') ? File.read('/proc/self/stat').split[0] : Process.pid
  puts "READY #{server.port} #{pid} workers=#{Kiln::Runtime.workers} pool=#{pool.size} loops=#{server.loops} mode=#{mode}"
  $stdout.flush
end
begin
  server.run(grace: 2.0)
ensure
  report.join
  pool.close
end
