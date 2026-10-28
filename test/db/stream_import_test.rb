require 'kiln/db'
require 'test/db/support'

Thread.current

class SiItem < Kiln::DB::Model
end

class StopStream < StandardError
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

def setup_items(conn)
  conn.exec('DROP TABLE IF EXISTS kiln_si_item', [])
  if conn.dialect == :postgres
    conn.exec('CREATE TABLE kiln_si_item (id INT PRIMARY KEY, name VARCHAR(40), v INT NOT NULL)', [])
  else
    conn.exec('CREATE TABLE kiln_si_item (id INT PRIMARY KEY, name VARCHAR(40), v INT NOT NULL) ENGINE=InnoDB', [])
  end
  SiItem.define_table(conn.dialect, 'kiln_si_item', %w[id name v], ['id'], 'si')
  rows = []
  i = 1
  while i <= 3000
    rows << { 'id' => i, 'name' => "n#{i}", 'v' => i % 7 }
    i += 1
  end
  SiItem.import(rows)
end

def ordered
  SiItem.all.order(SiItem.col('id').asc)
end

def check_stream(db, conn)
  count = 0
  sum = 0
  last = 0
  sorted = true
  ordered.stream do |row|
    sorted = false if row.get('id') <= last
    last = row.get('id')
    sum += row.get('v')
    count += 1
  end
  want = conn.exec('SELECT SUM(v) FROM kiln_si_item', [])[0][0].to_s.to_i
  need("#{db} stream count", count == 3000)
  need("#{db} stream sum", sum == want)
  need("#{db} stream order", sorted)
  line(db, 'stream', "#{count} rows")
end

def check_nested(db, conn)
  query_error = ''
  tx_error = ''
  seen = 0
  ordered.stream do |row|
    if seen.zero?
      begin
        SiItem.all.count
      rescue Kiln::DB::Error => e
        query_error = "#{e.class}: #{e.message}"
      end
      begin
        Kiln::DB.transaction { |connection| connection.depth }
      rescue Kiln::DB::Error => e
        tx_error = e.class.to_s
      end
    end
    seen += 1 if row.get('id').positive?
  end
  need("#{db} nested rows", seen == 3000)
  need("#{db} nested usable", !conn.broken? && conn.depth.zero?)
  need("#{db} nested after", SiItem.all.count == 3000)
  line(db, 'stream nested query', query_error)
  line(db, 'stream nested transaction', tx_error)
end

def check_early(db, conn)
  taken = 0
  ordered.stream do |row|
    taken += 1
    raise StopStream, 'stop' if taken == 10 && row.get('id') == 10
  end
rescue StopStream
  need("#{db} early usable", !conn.broken?)
  need("#{db} early after", SiItem.all.count == 3000)
  line(db, 'stream raise', "#{taken} rows, usable")
end

def check_break(db, conn)
  taken = 0
  ordered.stream do |row|
    taken += 1
    break if row.get('id') == 25
  end
  need("#{db} break usable", !conn.broken?)
  need("#{db} break after", SiItem.all.count == 3000)
  line(db, 'stream break', "#{taken} rows, usable")
end

def check_stream_error(db, conn)
  name = 'none'
  begin
    conn.each_row('SELECT missing_column FROM kiln_si_item', []) { |row| row }
  rescue Kiln::DB::Error => e
    name = e.class.to_s
  end
  need("#{db} stream error usable", !conn.broken?)
  need("#{db} stream error after", SiItem.all.count == 3000)
  line(db, 'stream error', "#{name}, usable")
end

def returned_names(result)
  names = []
  i = 0
  while i < result.returned.length
    names << result.returned[i][1].to_s
    i += 1
  end
  names
end

def check_cancel(db, conn)
  return nil if conn.dialect != :postgres

  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  taken = 0
  begin
    conn.each_row('SELECT generate_series(1, 50000000), repeat(\'x\', 100)', []) do |row|
      taken += 1
      raise StopStream, 'stop' if row[0] == 100
    end
  rescue StopStream
    nil
  end
  took = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  need("#{db} cancel fast", took < 3.0)
  need("#{db} cancel usable", !conn.broken?)
  need("#{db} cancel after", conn.exec('SELECT 1', [])[0][0] == 1)
  line(db, 'stream cancel', "#{taken} rows, usable")
end

def check_each_nested(db)
  counts = []
  ordered.where(SiItem.col('id').lte(3)).each do |row|
    counts << SiItem.all.where(SiItem.col('id').eq(row.get('id'))).count
  end
  names = ordered.where(SiItem.col('id').lte(2)).map do |row|
    "#{row.get('name')}/#{SiItem.all.where(SiItem.col('v').eq(row.get('v'))).count}"
  end
  need("#{db} each nested", counts.length == 3 && counts[0] == 1 && counts[2] == 1)
  line(db, 'each nested', "#{counts.length} #{names.join(',')}")
end

def returned_ids(result)
  ids = []
  i = 0
  while i < result.returned.length
    ids << result.returned[i][0].to_s
    i += 1
  end
  ids
end

def statuses(result)
  out = []
  i = 0
  while i < result.length
    out << result.input_status(i)
    i += 1
  end
  out
end

def check_import_pg(db)
  rows = [
    { 'id' => 1, 'name' => 'dup', 'v' => 1 },
    { 'id' => 5000, 'name' => 'a', 'v' => 1 },
    { 'id' => 5000, 'name' => 'b', 'v' => 2 },
    { 'id' => 5001, 'v' => 3 },
    { 'id' => 5002, 'name' => 'c', 'v' => 4 },
    { 'id' => 5001, 'name' => 'd', 'v' => 5 }
  ]
  result = SiItem.import(rows, { on_duplicate_key_ignore: true, returning: true })
  line(db, 'import ignore status', statuses(result).join(','))
  line(db, 'import ignore returned', returned_ids(result).join(','))
  line(db, 'import ignore names', returned_names(result).join(','))
  big = []
  i = 0
  while i < 2500
    big << { 'id' => 10_000 + ((i * 7919) % 2500), 'name' => 'p', 'v' => i % 3 }
    i += 1
  end
  result = SiItem.import(big, { returning: true })
  ids = returned_ids(result)
  ordered_ok = ids.length == 2500
  i = 0
  while ordered_ok && i < big.length
    ordered_ok = ids[i] == big[i]['id'].to_s
    i += 1
  end
  need("#{db} import paged order", ordered_ok)
  line(db, 'import paged', "#{ids.length} returned in input order")
end

def check_import_my(db)
  big = []
  i = 0
  while i < 2500
    big << { 'id' => 10_000 + ((i * 7919) % 2500), 'name' => 'p', 'v' => i % 3 }
    i += 1
  end
  result = SiItem.import(big, { returning: true })
  ids = returned_ids(result)
  ordered_ok = ids.length == 2500
  i = 0
  while ordered_ok && i < big.length
    ordered_ok = ids[i] == big[i]['id'].to_s
    i += 1
  end
  need("#{db} import paged order", ordered_ok)
  line(db, 'import paged', "#{ids.length} returned in input order")
  rows = [
    { 'id' => 1, 'name' => 'first', 'v' => 1 },
    { 'id' => 1, 'name' => 'second', 'v' => 2 },
    { 'id' => 20_000, 'name' => 'new', 'v' => 3 }
  ]
  result = SiItem.import(rows, { on_duplicate_key_update: true, returning: true })
  names = []
  i = 0
  while i < result.returned.length
    names << result.returned[i][1].to_s
    i += 1
  end
  line(db, 'import upsert status', statuses(result).join(','))
  line(db, 'import upsert returned', names.join(','))
  conn = Kiln::DB::Scope.current
  conn.exec('DROP TABLE IF EXISTS kiln_si_code', [])
  conn.exec('CREATE TABLE kiln_si_code (id VARCHAR(20) PRIMARY KEY, name VARCHAR(40), v INT NOT NULL) ENGINE=InnoDB',
            [])
  SiItem.define_table(conn.dialect, 'kiln_si_code', %w[id name v], ['id'], 'sc')
  SiItem.import([{ 'id' => 'ABC', 'name' => 'old', 'v' => 1 }, { 'id' => 'X1', 'name' => 'old', 'v' => 1 }])
  rows = [
    { 'id' => 'abc', 'name' => 'case', 'v' => 2 },
    { 'id' => 'X1', 'name' => 'exact', 'v' => 3 },
    { 'id' => 'new', 'name' => 'fresh', 'v' => 4 }
  ]
  result = SiItem.import(rows, { on_duplicate_key_update: true, returning: true })
  line(db, 'import collation status', statuses(result).join(','))
  line(db, 'import collation returned', "#{returned_ids(result).join(',')} #{returned_names(result).join(',')}")
  conn.exec('DROP TABLE kiln_si_code', [])
  SiItem.define_table(conn.dialect, 'kiln_si_item', %w[id name v], ['id'], 'si')
end

def check_pool_closed(db, kind, host, port, user, password, database, ca_path, tls_name)
  pool = Kiln::DB::Pool.new(1, timeout: 2.0) do
    Kiln::DB::Conn.open(kind, host, port, user, password, database, ca_path, tls_name)
  end
  pool.with { |conn| conn.exec('SELECT 1', []) }
  closed = pool.close
  name = 'none'
  begin
    pool.checkout
  rescue Exception => e
    name = e.class.to_s
  end
  line(db, 'pool closed', "#{closed} #{name}")
end

def run_one(db, kind, host, port, user, password, database, ca_path, tls_name)
  conn = Kiln::DB::Conn.open(kind, host, port, user, password, database, ca_path, tls_name)
  Kiln::DB::Scope.use(conn)
  setup_items(conn)
  check_stream(db, conn)
  check_nested(db, conn)
  check_early(db, conn)
  check_break(db, conn)
  check_stream_error(db, conn)
  check_cancel(db, conn)
  check_each_nested(db)
  if conn.dialect == :postgres
    check_import_pg(db)
  else
    check_import_my(db)
  end
  conn.exec('DROP TABLE kiln_si_item', [])
  Kiln::DB::Scope.use(nil)
  conn.close
  check_pool_closed(db, kind, host, port, user, password, database, ca_path, tls_name)
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
  i += 1
end
print "ok stream import\n"
