require 'kiln/db'
require 'test/db/support'

Thread.current

class FixUser < Kiln::DB::Model
end

class FixWide < Kiln::DB::Model
end

class FixAuto < Kiln::DB::Model
end

class FixFlag < Kiln::DB::Model
end

def line(db, label, value)
  print db
  print ' '
  print label
  print ' '
  print value
  print "\n"
end

def need(label, cond)
  return if cond

  print "FAILED #{label}\n"
  raise label
end

def ddl(conn, sql)
  conn.exec(sql, [])
end

def wide_names
  names = ['id']
  i = 1
  while i < 20
    names << "c#{i}"
    i += 1
  end
  names
end

def setup_tables(conn)
  ddl(conn, 'DROP TABLE IF EXISTS kiln_fix_child')
  ddl(conn, 'DROP TABLE IF EXISTS kiln_fix_user')
  ddl(conn, 'DROP TABLE IF EXISTS kiln_fix_wide')
  ddl(conn, 'DROP TABLE IF EXISTS kiln_fix_auto')
  ddl(conn, 'DROP TABLE IF EXISTS kiln_fix_flag')
  ddl(conn, 'DROP TABLE IF EXISTS kiln_fix_types')
  ddl(conn, 'DROP TABLE IF EXISTS kiln_fix_blob')
  ddl(conn, 'DROP TABLE IF EXISTS kiln_fix_big')
  if conn.dialect == :postgres
    ddl(conn,
        'CREATE TABLE kiln_fix_user (id INT PRIMARY KEY, name VARCHAR(80) NOT NULL UNIQUE, score INT CHECK (score >= 0))')
    ddl(conn, 'CREATE TABLE kiln_fix_child (id INT PRIMARY KEY, user_id INT NOT NULL REFERENCES kiln_fix_user(id))')
    ddl(conn, 'CREATE TABLE kiln_fix_auto (id SERIAL PRIMARY KEY, name VARCHAR(40) NOT NULL)')
    ddl(conn, 'CREATE TABLE kiln_fix_flag (id INT PRIMARY KEY, active BOOLEAN)')
    ddl(conn, 'CREATE TABLE kiln_fix_types (i BIGINT, d NUMERIC(20,4), f DOUBLE PRECISION, b BOOLEAN, t TEXT, n INT)')
    ddl(conn, 'CREATE TABLE kiln_fix_blob (id INT PRIMARY KEY, data BYTEA, body TEXT)')
    ddl(conn, 'CREATE TABLE kiln_fix_big (id INT PRIMARY KEY, v INT NOT NULL)')
  else
    ddl(conn,
        'CREATE TABLE kiln_fix_user (id INT PRIMARY KEY, name VARCHAR(80) NOT NULL UNIQUE, score INT, CHECK (score >= 0)) ENGINE=InnoDB')
    ddl(conn,
        'CREATE TABLE kiln_fix_child (id INT PRIMARY KEY, user_id INT NOT NULL, FOREIGN KEY (user_id) REFERENCES kiln_fix_user(id)) ENGINE=InnoDB')
    ddl(conn, 'CREATE TABLE kiln_fix_auto (id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(40) NOT NULL) ENGINE=InnoDB')
    ddl(conn, 'CREATE TABLE kiln_fix_flag (id INT PRIMARY KEY, active TINYINT(1)) ENGINE=InnoDB')
    ddl(conn,
        'CREATE TABLE kiln_fix_types (i BIGINT UNSIGNED, d DECIMAL(20,4), f DOUBLE, b TINYINT(1), t LONGTEXT, n INT) ENGINE=InnoDB')
    ddl(conn, 'CREATE TABLE kiln_fix_blob (id INT PRIMARY KEY, data LONGBLOB, body LONGTEXT) ENGINE=InnoDB')
    ddl(conn, 'CREATE TABLE kiln_fix_big (id INT PRIMARY KEY, v INT NOT NULL) ENGINE=InnoDB')
  end
  cols = ''
  names = wide_names
  i = 1
  while i < names.length
    cols += ", #{names[i]} VARCHAR(20)"
    i += 1
  end
  ddl(conn, "CREATE TABLE kiln_fix_wide (id INT PRIMARY KEY#{cols})")
  FixUser.define_table(conn.dialect, 'kiln_fix_user', %w[id name score], ['id'], 'fu')
  FixWide.define_table(conn.dialect, 'kiln_fix_wide', wide_names, ['id'], 'fw')
  FixAuto.define_table(conn.dialect, 'kiln_fix_auto', %w[id name], ['id'], 'fa')
  FixFlag.define_table(conn.dialect, 'kiln_fix_flag', %w[id active], ['id'], 'ff')
end

def check_utf8(db, conn)
  text = 'Ёж 🦔 日本'
  FixUser.new({ 'id' => 1, 'name' => text, 'score' => 1 }).save!
  got = FixUser.all.where(FixUser.col('name').eq(text)).pluck(FixUser.col('name'))
  need("#{db} utf8 found", got.length == 1)
  need("#{db} utf8 equal", got[0] == text)
  need("#{db} utf8 encoding", got[0].encoding.to_s == 'UTF-8')
  raw = conn.exec(
    conn.dialect == :postgres ? 'SELECT octet_length(name) FROM kiln_fix_user WHERE id = 1' : 'SELECT LENGTH(name) FROM kiln_fix_user WHERE id = 1', []
  )
  need("#{db} utf8 bytes", raw[0][0] == text.bytesize)
  blob = [0, 1, 255, 0, 200, 65].pack('C*')
  sql = conn.dialect == :postgres ? 'INSERT INTO kiln_fix_blob (id, data, body) VALUES ($1, $2, $3)' : 'INSERT INTO kiln_fix_blob (id, data, body) VALUES (?, ?, ?)'
  conn.exec(sql, [1, blob, 'x'])
  back = conn.exec('SELECT data FROM kiln_fix_blob WHERE id = 1', [])
  need("#{db} blob equal", back[0][0] == blob)
  line(db, 'utf8', "#{got[0].bytesize} blob #{back[0][0].bytesize}")
end

def check_wide(db, _conn)
  names = wide_names
  rows = []
  r = 0
  while r < 50
    attrs = { 'id' => r + 1 }
    i = 1
    while i < names.length
      attrs[names[i]] = "v#{r}_#{i}"
      i += 1
    end
    rows << attrs
    r += 1
  end
  result = FixWide.import(rows)
  need("#{db} wide import", result.state == 'COMMITTED' && result.length == 50)
  one = { 'id' => 100 }
  i = 1
  while i < names.length
    one[names[i]] = 'single'
    i += 1
  end
  FixWide.new(one).save!
  models = FixWide.all.order(FixWide.col('id').asc).models
  need("#{db} wide models", models.length == 51)
  need("#{db} wide last col", models[0].attrs['c19'] == 'v0_19')
  line(db, 'wide', "#{models.length} cols #{names.length}")
end

def check_binds(db, _conn)
  ids = []
  i = 1
  while i <= 100
    ids << i
    i += 1
  end
  n = FixWide.all.where(FixWide.col('id').in(ids)).count
  need("#{db} in100", n == 51)
  line(db, 'in100', n.to_s)
end

def check_big(db, conn)
  rows = []
  i = 0
  while i < 10_000
    rows << { 'id' => i + 1, 'v' => i % 7 }
    i += 1
  end
  FixBig.define_table(conn.dialect, 'kiln_fix_big', %w[id v], ['id'], 'fb')
  result = FixBig.import(rows)
  need("#{db} big import", result.length == 10_000)
  all = FixBig.all.to_a
  sum = 0
  i = 0
  while i < all.length
    sum += all[i][1]
    i += 1
  end
  need("#{db} big rows", all.length == 10_000)
  need("#{db} big exists", FixBig.all.exists?)
  limited = FixBig.all.order(FixBig.col('id').asc).limit(3).count
  offset_rows = FixBig.all.order(FixBig.col('id').asc).offset(9998).pluck(FixBig.col('id'))
  distinct_n = FixBig.all.select(FixBig.col('v')).distinct.count
  line(db, 'big',
       "#{all.length} sum #{sum} limit #{limited} offset #{offset_rows.length} distinct #{distinct_n}")
end

class FixBig < Kiln::DB::Model
end

def check_types(db, conn)
  if conn.dialect == :postgres
    conn.exec('INSERT INTO kiln_fix_types VALUES ($1, $2, $3, $4, $5, $6)',
              [9_223_372_036_854_775_807, '12.5000', 1.5, true, 'txt', nil])
  else
    conn.exec('INSERT INTO kiln_fix_types VALUES (?, ?, ?, ?, ?, ?)',
              ['18446744073709551615', '12.5000', 1.5, true, 'txt', nil])
  end
  row = conn.exec('SELECT i, d, f, b, t, n FROM kiln_fix_types', [])[0]
  i_ok = conn.dialect == :postgres ? row[0] == 9_223_372_036_854_775_807 : row[0].is_a?(Kiln::DB::UInt64Value) && row[0].to_s == '18446744073709551615'
  b_ok = conn.dialect == :postgres ? row[3] == true : row[3] == 1
  need("#{db} type int", i_ok)
  need("#{db} type decimal", row[1].is_a?(Kiln::DB::ExactDecimal) && row[1] == Kiln::DB::ExactDecimal.parse('12.5'))
  need("#{db} type float", row[2].is_a?(Float) && row[2] == 1.5)
  need("#{db} type bool", b_ok)
  need("#{db} type text", row[4] == 'txt')
  need("#{db} type null", row[5].nil?)
  line(db, 'types',
       "#{row[0].class.to_s.split('::').last} #{row[1].class.to_s.split('::').last} #{row[2].class} #{row[3]} #{row[5].inspect}")
end

def check_bool(db, conn)
  FixFlag.import([{ 'id' => 1, 'active' => true }, { 'id' => 2, 'active' => false }, { 'id' => 3, 'active' => nil }])
  on = FixFlag.all.where(FixFlag.col('active').eq(true)).pluck(FixFlag.col('id'))
  off = FixFlag.all.where(FixFlag.col('active').eq(false)).pluck(FixFlag.col('id'))
  need("#{db} bool true", on.length == 1 && on[0] == 1)
  need("#{db} bool false", off.length == 1 && off[0] == 2)
  line(db, 'bool',
       "#{on.inspect} #{off.inspect} warnings #{conn.dialect == :postgres ? '0' : conn.warning_count.to_s}")
end

def error_name(err)
  err.class.to_s.split('::').last
end

def try_sql(conn, sql, binds)
  conn.exec(sql, binds)
  'none'
rescue Kiln::DB::Error => e
  "#{error_name(e)}:#{e.sqlstate}"
end

def check_errors(db, conn)
  ph = conn.dialect == :postgres ? ['$1', '$2', '$3'] : ['?', '?', '?']
  ins = "INSERT INTO kiln_fix_user (id, name, score) VALUES (#{ph[0]}, #{ph[1]}, #{ph[2]})"
  unique = try_sql(conn, ins, [2, 'Ёж 🦔 日本', 1])
  notnull = try_sql(conn, ins, [3, nil, 1])
  check = try_sql(conn, ins, [4, 'neg', -1])
  child = conn.dialect == :postgres ? 'INSERT INTO kiln_fix_child (id, user_id) VALUES ($1, $2)' : 'INSERT INTO kiln_fix_child (id, user_id) VALUES (?, ?)'
  fk = try_sql(conn, child, [1, 999])
  line(db, 'errors', "#{unique} #{notnull} #{check} #{fk}")
end

def check_nested(db, conn)
  Kiln::DB.transaction do
    FixAuto.new({ 'name' => 'outer' }).save!
    begin
      Kiln::DB.transaction do
        FixAuto.new({ 'name' => 'inner' }).save!
        raise ArgumentError, 'inner'
      end
    rescue ArgumentError
      nil
    end
  end
  names = FixAuto.all.order(FixAuto.col('id').asc).pluck(FixAuto.col('name'))
  need("#{db} nested", names.length == 1 && names[0] == 'outer')
  need("#{db} depth", conn.depth.zero?)
  line(db, 'nested', names.inspect)
end

def check_auto(db, _conn)
  m = FixAuto.new({ 'name' => 'auto' })
  m.save!
  id = m.attrs['id']
  need("#{db} auto id", id.is_a?(Integer) && id.positive?)
  m.assign('name', 'renamed')
  m.save!
  back = FixAuto.all.where(FixAuto.col('id').eq(id)).pluck(FixAuto.col('name'))
  need("#{db} auto update", back[0] == 'renamed')
  line(db, 'auto', "id-integer #{back[0]}")
end

def check_import_outer(db, _conn)
  inner_state = nil
  begin
    Kiln::DB.transaction do
      inner_state = FixWide.import([{ 'id' => 500, 'c1' => 'x' }]).state
      raise ArgumentError, 'outer rollback'
    end
  rescue ArgumentError
    nil
  end
  left = FixWide.all.where(FixWide.col('id').eq(500)).count
  plain = FixWide.import([{ 'id' => 501, 'c1' => 'y' }]).state
  need("#{db} import pending", inner_state == 'PENDING_COMMIT' && left.zero? && plain == 'COMMITTED')
  line(db, 'import', "#{inner_state} #{left} #{plain}")
end

def check_commit_failure(db, conn)
  return line(db, 'commit-fail', 'n/a') if conn.dialect != :postgres

  ddl(conn, 'DROP TABLE IF EXISTS kiln_fix_defer')
  ddl(conn, 'CREATE TABLE kiln_fix_defer (k INT, CONSTRAINT kiln_fix_defer_u UNIQUE (k) DEFERRABLE INITIALLY DEFERRED)')
  got = 'none'
  begin
    Kiln::DB.transaction do
      conn.exec('INSERT INTO kiln_fix_defer (k) VALUES (1), (1)', [])
    end
  rescue Kiln::DB::Error => e
    got = error_name(e)
  end
  need("#{db} commit depth", conn.depth.zero?)
  Kiln::DB.transaction do
    conn.exec('INSERT INTO kiln_fix_defer (k) VALUES (2)', [])
  end
  n = conn.exec('SELECT count(*) FROM kiln_fix_defer', [])[0][0]
  ddl(conn, 'DROP TABLE kiln_fix_defer')
  line(db, 'commit-fail', "#{got} depth #{conn.depth} after #{n}")
end

def check_inline(db, conn)
  Thread.current[:kiln_inline] = true
  got = 'none'
  begin
    conn.exec('SELECT 1', [])
  rescue Kiln::DB::Unsupported
    got = 'Unsupported'
  end
  Thread.current[:kiln_inline] = nil
  line(db, 'inline', got)
end

def check_deadline(db, conn)
  sleep_sql = conn.dialect == :postgres ? 'SELECT pg_sleep(3)' : 'SELECT SLEEP(3)'
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  Thread.current[:kiln_deadline] = started + 0.4
  got = 'none'
  begin
    conn.exec(sleep_sql, [])
  rescue Kiln::DB::Timeout
    got = 'Timeout'
  end
  Thread.current[:kiln_deadline] = nil
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  need("#{db} deadline elapsed", elapsed < 2.5)
  after = 'n/a'
  if conn.dialect == :postgres
    need("#{db} pg reusable", !conn.broken?)
    after = conn.exec('SELECT 42', [])[0][0].to_s
    begin
      Kiln::DB.transaction do
        conn.exec('INSERT INTO kiln_fix_flag (id, active) VALUES (99, true)', [])
        raise ArgumentError, 'rollback'
      end
    rescue ArgumentError
      nil
    end
    left = conn.exec('SELECT count(*) FROM kiln_fix_flag WHERE id = 99', [])[0][0]
    need("#{db} rollback after timeout", left.zero?)
  else
    need("#{db} my broken", conn.broken?)
    after = 'broken'
  end
  line(db, 'deadline', "#{got} #{after}")
end

def check_prepared(db, conn)
  return line(db, 'prepared', 'n/a') if conn.dialect != :postgres

  i = 0
  while i < 200
    FixBig.all.where(FixBig.col('id').eq(i + 1)).count
    i += 1
  end
  n = conn.exec('SELECT count(*) FROM pg_prepared_statements', [])[0][0].to_s.to_i
  line(db, 'prepared', n <= 32 ? 'bounded' : n.to_s)
end

def check_long(db, conn)
  body = 'x' * 1_000_000
  sql = conn.dialect == :postgres ? 'INSERT INTO kiln_fix_blob (id, data, body) VALUES ($1, $2, $3)' : 'INSERT INTO kiln_fix_blob (id, data, body) VALUES (?, ?, ?)'
  conn.exec(sql, [2, nil, body])
  back = conn.exec('SELECT body FROM kiln_fix_blob WHERE id = 2', [])
  need("#{db} long text", back[0][0].bytesize == 1_000_000)
  line(db, 'longtext', back[0][0].bytesize.to_s)
end

def run_one(db, kind, host, port, user, password, database, ca_path, tls_name)
  conn = Kiln::DB::Conn.open(kind, host, port, user, password, database, ca_path, tls_name)
  Kiln::DB::Scope.use(conn)
  setup_tables(conn)
  check_utf8(db, conn)
  check_wide(db, conn)
  check_binds(db, conn)
  check_big(db, conn)
  check_types(db, conn)
  check_bool(db, conn)
  check_errors(db, conn)
  check_nested(db, conn)
  check_auto(db, conn)
  check_import_outer(db, conn)
  check_commit_failure(db, conn)
  check_inline(db, conn)
  check_prepared(db, conn)
  check_long(db, conn)
  check_deadline(db, conn)
  Kiln::DB::Scope.use(nil)
  conn.close_quietly
end

def check_pool(db, kind, host, port, user, password, database, ca_path, tls_name)
  pool = Kiln::DB::Pool.new(2, timeout: 5.0) do
    Kiln::DB::Conn.open(kind, host, port, user, password, database, ca_path, tls_name)
  end
  Kiln::DB::Scope.pool = pool
  Kiln::DB::Scope.lease { |conn| conn.exec('DELETE FROM kiln_fix_flag', []) }
  ph = kind == Kiln::DB::Native::KIND_PG ? '$1' : '?'
  seen = []
  lock = Mutex.new
  a = Thread.new do
    Kiln::DB.transaction do |conn|
      conn.exec("INSERT INTO kiln_fix_flag (id, active) VALUES (#{ph}, NULL)", [7])
      sleep 0.3
      raise ArgumentError, 'rollback a'
    end
  rescue ArgumentError
    nil
  end
  sleep 0.1
  b = Thread.new do
    n = Kiln::DB::Scope.lease { |conn| conn.exec('SELECT count(*) FROM kiln_fix_flag WHERE id = 7', [])[0][0] }
    lock.synchronize { seen << n }
    nil
  end
  a.join
  b.join
  after = Kiln::DB::Scope.lease { |conn| conn.exec('SELECT count(*) FROM kiln_fix_flag WHERE id = 7', [])[0][0] }
  need("#{db} pool isolation", seen.length == 1 && seen[0].zero? && after.zero?)
  tokens_ok = true
  waits = 0
  threads = []
  t = 0
  while t < 4
    threads << Thread.new do
      moved = Kiln::DB::Scope.lease do |conn|
        changed = 0
        i = 0
        while i < 25
          before = Kiln::DB::Native.os_thread_token
          conn.exec(kind == Kiln::DB::Native::KIND_PG ? 'SELECT pg_sleep(0.002)' : 'SELECT SLEEP(0.002)', [])
          changed += 1 if before != Kiln::DB::Native.os_thread_token
          i += 1
        end
        changed
      end
      lock.synchronize do
        tokens_ok = false if moved != 0
        waits += 25
      end
      nil
    end
    t += 1
  end
  i = 0
  while i < threads.length
    threads[i].join
    i += 1
  end
  need("#{db} pinning", tokens_ok)
  Kiln::DB::Scope.pool = nil
  pool.close
  line(db, 'pool', "isolated pinned #{waits}")
end

path = 'build/db-runtime/session.env'
text = File.read(path)
ca_path = "#{env_line(text, 'KILN_DB_CONFIG_DIR')}/ca.crt"
tls_name = env_line(text, 'KILN_DB_TLS_NAME')
targets = [
  ['pg', Kiln::DB::Native::KIND_PG, 'DB_PG17', 'KILN_DB_PG'],
  ['mysql', Kiln::DB::Native::KIND_MY, 'DB_MY', 'KILN_DB_MY'],
  ['mariadb', Kiln::DB::Native::KIND_MY, 'DB_MARIA', 'KILN_DB_MY']
]
i = 0
while i < targets.length
  t = targets[i]
  host = env_line(text, "#{t[2]}_HOST")
  port = env_line(text, "#{t[2]}_PORT").to_i
  user = env_line(text, "#{t[3]}_USER")
  password = env_line(text, "#{t[3]}_PASSWORD")
  database = env_line(text, "#{t[3]}_DB")
  run_one(t[0], t[1], host, port, user, password, database, ca_path, tls_name)
  check_pool(t[0], t[1], host, port, user, password, database, ca_path, tls_name)
  i += 1
end
print "ok fix regression\n"
