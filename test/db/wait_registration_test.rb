require 'kiln/db'
require 'test/db/support'

Thread.current

def need(label, cond)
  return if cond

  print "FAILED #{label}\n"
  raise label
end

def line(db, label, value)
  print "#{db} #{label} #{value}\n"
end

def epoll_entries
  return -1 unless File.directory?('/proc/self/fdinfo')

  total = 0
  Dir.children('/proc/self/fdinfo').each do |name|
    text = begin
      File.read("/proc/self/fdinfo/#{name}")
    rescue SystemCallError
      ''
    end
    text.each_line { |entry| total += 1 if entry.start_with?('tfd:') }
  end
  total
end

class Target
  attr_reader :db, :kind

  def initialize(db, kind, text, host_key, auth_key)
    @db = db
    @kind = kind
    @text = text
    @host_key = host_key
    @auth_key = auth_key
  end

  def open
    Kiln::DB::Conn.open(@kind, env_line(@text, "#{@host_key}_HOST"), env_line(@text, "#{@host_key}_PORT").to_i,
                        env_line(@text, "#{@auth_key}_USER"), env_line(@text, "#{@auth_key}_PASSWORD"),
                        env_line(@text, "#{@auth_key}_DB"), "#{env_line(@text, 'KILN_DB_CONFIG_DIR')}/ca.crt",
                        env_line(@text, 'KILN_DB_TLS_NAME'))
  end

  def postgres? = @kind == Kiln::DB::Native::KIND_PG
  def session_sql = postgres? ? 'SELECT pg_backend_pid()' : 'SELECT CONNECTION_ID()'

  def alive_sql
    if postgres?
      'SELECT COUNT(*) FROM pg_stat_activity WHERE pid = $1'
    else
      'SELECT COUNT(*) FROM information_schema.processlist WHERE id = ?'
    end
  end
end

def pooled_queries(target, threads, rounds)
  sql = target.postgres? ? 'SELECT $1::int' : 'SELECT CAST(? AS SIGNED)'
  pool = Kiln::DB::Pool.new(4, timeout: 5.0) { target.open }
  baseline = fd_count
  workers = Array.new(threads) do |index|
    Thread.new do
      ok = true
      peak = baseline
      rounds.times do |round|
        conn = pool.checkout
        begin
          value = (index * 1000) + round
          ok = false unless conn.exec(sql, [value])[0][0] == value
          if index.zero? && (round % 20).zero?
            now = fd_count
            peak = now if now > peak
          end
        ensure
          pool.checkin(conn)
        end
      end
      [ok, peak]
    end
  end
  all = true
  peak = baseline
  workers.each do |worker|
    ok, local_peak = worker.value
    all = false unless ok
    peak = local_peak if local_peak > peak
  end
  finish = fd_count
  peak = finish if finish > peak
  entries = epoll_entries
  need("#{target.db} pool close", pool.close(timeout: 5.0).zero?)
  growth = baseline.negative? || peak.negative? ? nil : peak - baseline
  [all, entries, growth]
end

def check_bounded(target)
  ok, entries, growth = pooled_queries(target, 4, 2000)
  need("#{target.db} pooled results", ok)
  observed = false
  if File.directory?('/proc/self/fdinfo')
    need("#{target.db} epoll entries bounded (#{entries})", entries >= 0 && entries <= 32)
    observed = true
  end
  unless growth.nil?
    need("#{target.db} open fds bounded (#{growth})", growth <= 64)
    observed = true
  end
  need("#{target.db} registration observed", observed)
  line(target.db, 'registrations', 'bounded')
end

def check_close_releases(target)
  observer = target.open
  conn = target.open
  6.times { |i| need("#{target.db} reuse #{i}", conn.exec('SELECT 1', [])[0][0] == 1) }
  session = conn.exec(target.session_sql, [])[0][0]
  conn.close
  alive = 1
  20.times do
    alive = observer.exec(target.alive_sql, [session])[0][0]
    break if alive.zero?

    sleep 0.05
  end
  observer.close
  need("#{target.db} server session ended", alive.zero?)
  line(target.db, 'close ends server session', 'yes')
end

def check_cancel_reuse(target)
  return unless target.postgres?

  conn = target.open
  conn.exec('SELECT 1', [])
  conn.timeout = 0.05
  timed_out = false
  begin
    conn.exec('SELECT pg_sleep(0.5)', [])
  rescue Kiln::DB::Timeout
    timed_out = true
  end
  conn.timeout = 5.0
  need("#{target.db} timeout", timed_out)
  need("#{target.db} query after cancel", conn.exec('SELECT 9', [])[0][0] == 9)
  conn.pipeline_begin
  conn.pipeline_exec('SELECT 11', [])
  conn.pipeline_sync
  need("#{target.db} pipeline read", conn.pipeline_read[0][0] == 11)
  conn.pipeline_sync_read
  conn.pipeline_finish
  need("#{target.db} query after pipeline", conn.exec('SELECT 13', [])[0][0] == 13)
  conn.close
  line(target.db, 'cancel and pipeline reuse', 'ok')
end

def check_streaming(target)
  conn = target.open
  sql = if target.postgres?
          'SELECT g FROM generate_series(1, 3000) g'
        else
          'WITH RECURSIVE s(g) AS (SELECT 1 UNION ALL SELECT g + 1 FROM s WHERE g < 3000) SELECT g FROM s'
        end
  conn.exec('SET SESSION cte_max_recursion_depth = 5000', []) if target.db == 'mysql84'
  conn.exec('SET SESSION max_recursive_iterations = 5000', []) if target.db == 'mariadb114'
  count = 0
  conn.each_row(sql, []) do |row|
    count += 1
    break if count == 1500 && !row.empty?
  end
  need("#{target.db} streamed rows", count == 1500)
  need("#{target.db} usable after break", conn.exec('SELECT 5', [])[0][0] == 5 && !conn.broken?)
  conn.close
  line(target.db, 'stream break reuse', 'ok')
end

text = File.read('build/db-runtime/session.env')
targets = [
  Target.new('pg17', Kiln::DB::Native::KIND_PG, text, 'DB_PG17', 'KILN_DB_PG'),
  Target.new('mysql84', Kiln::DB::Native::KIND_MY, text, 'DB_MY', 'KILN_DB_MY'),
  Target.new('mariadb114', Kiln::DB::Native::KIND_MY, text, 'DB_MARIA', 'KILN_DB_MY')
]
targets.each do |target|
  check_bounded(target)
  check_close_releases(target)
  check_cancel_reuse(target)
  check_streaming(target)
end
print "ok wait registration\n"
