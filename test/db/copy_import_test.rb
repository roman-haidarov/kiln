require 'kiln/db'
require 'test/db/support'

Thread.current

class CopyVal < Kiln::DB::Model
end

class CopyIns < Kiln::DB::Model
end

class CopyDup < Kiln::DB::Model
end

class CopyTx < Kiln::DB::Model
end

class CopyBig < Kiln::DB::Model
end

class CopyBin < Kiln::DB::Model
end

class CopyStamp < Kiln::DB::Model
end

class InsStamp < Kiln::DB::Model
end

TABLES = %w[kiln_p10_copy kiln_p10_copy_ins kiln_p10_copy_dup kiln_p10_copy_tx kiln_p10_copy_big kiln_p10_copy_bin
            kiln_p10_copy_stamp kiln_p10_ins_stamp].freeze
STAMP_COLS = 'id INT PRIMARY KEY, created_at TIMESTAMPTZ, updated_at TIMESTAMP'.freeze

def need(label, cond)
  return if cond

  print "FAILED #{label}\n"
  raise label
end

def open_db(text, timeout = 30)
  ca = "#{env_line(text, 'KILN_DB_CONFIG_DIR')}/ca.crt"
  Kiln::DB::Conn.open(Kiln::DB::Native::KIND_PG, env_line(text, 'DB_PG17_HOST'), env_line(text, 'DB_PG17_PORT').to_i,
                      env_line(text, 'KILN_DB_PG_USER'), env_line(text, 'KILN_DB_PG_PASSWORD'),
                      env_line(text, 'KILN_DB_PG_DB'), ca, env_line(text, 'KILN_DB_TLS_NAME'), timeout: timeout)
end

def count_of(conn, sql)
  conn.exec(sql, [])[0][0].to_s.to_i
end

def cell_same?(left, right)
  return false unless left.class == right.class
  return left.encoding == right.encoding && left == right if left.is_a?(String)
  return left.inspect == right.inspect if left.is_a?(Float)

  left == right
end

def row_same?(left, right)
  return false unless left.length == right.length

  i = 0
  while i < left.length
    return false unless cell_same?(left[i], right[i])

    i += 1
  end
  true
end

def rows_same?(left, right)
  return false unless left.length == right.length

  i = 0
  while i < left.length
    return false unless row_same?(left[i], right[i])

    i += 1
  end
  true
end

def check_text
  special = "a\tb\nc\\d\r"
  got = Kiln::DB::Import.copy_text([[nil, special]])
  need('copy_text', got == (+"\\N\ta\\tb\\nc\\\\d\\r\n").b)
  wide = []
  i = 0
  while i < 3
    wide << ['x' * 10]
    i += 1
  end
  payload, count = Kiln::DB::Import.copy_chunk(wide, 0, 25)
  need('chunk', count == 2 && payload.bytesize <= 25)
  one, alone = Kiln::DB::Import.copy_chunk([['y' * 30]], 0, 10)
  need('chunk one', alone == 1 && one.bytesize > 10)
  plain = Kiln::DB::ImportMode.new(false, false, false)
  binary = (+'').b
  binary << 255
  need('plain', Kiln::DB::Import.copy_eligible?(:postgres, plain, [[1, 'a', nil, true, false]]))
  need('binary', !Kiln::DB::Import.copy_eligible?(:postgres, plain, [[binary]]))
  need('returning', !Kiln::DB::Import.copy_eligible?(:postgres, Kiln::DB::ImportMode.new(false, false, true), [[1]]))
  need('ignore', !Kiln::DB::Import.copy_eligible?(:postgres, Kiln::DB::ImportMode.new(true, false, false), [[1]]))
  need('update', !Kiln::DB::Import.copy_eligible?(:postgres, Kiln::DB::ImportMode.new(false, true, false), [[1]]))
  need('mysql', !Kiln::DB::Import.copy_eligible?(:mysql, plain, [[1, 'a']]))
  need('stamp shape', Kiln::DB::Import.copy_shape(:postgres, plain, [[1, :timestamp]]) == 1)
  need('stamp text', Kiln::DB::Import.copy_text([[1, :timestamp]], 'S'.b) == (+"1\tS\n").b)
  print "copy_text ok\n"
end

def value_rows
  dec = Kiln::DB::ExactDecimal.parse('12345678901234567890.123456789')
  [
    { 'id' => 1, 's' => nil, 'n' => nil, 'f' => nil, 'd' => nil, 'b' => nil },
    { 'id' => 2, 's' => '', 'n' => Kiln::DB::Int64Value.min_value, 'f' => 1e20, 'd' => dec, 'b' => true },
    { 'id' => 3, 's' => "a\tb\nc\\d\r", 'n' => Kiln::DB::Int64Value.max_value, 'f' => -0.0, 'd' => nil, 'b' => false },
    { 'id' => 4, 's' => 'ä😀', 'n' => nil, 'f' => 5e-324, 'd' => nil, 'b' => nil }
  ]
end

def read_values(conn, table)
  conn.exec("SELECT id, s, n, f, d, b FROM #{table} ORDER BY id", [])
end

def check_values(conn)
  rows = value_rows
  copied = CopyVal.import(rows)
  inserted = CopyIns.import(rows, { returning: true })
  need('values status', copied.state == 'COMMITTED' && inserted.state == 'COMMITTED')
  need('values rows', rows_same?(read_values(conn, 'kiln_p10_copy'), read_values(conn, 'kiln_p10_copy_ins')))
  print "copy_values match\n"
end

def check_duplicate(conn)
  err = nil
  begin
    CopyDup.import([
                     { 'id' => 1, 'name' => 'a' },
                     { 'id' => 2, 'name' => 'b' },
                     { 'id' => 2, 'name' => 'dup' },
                     { 'id' => 3, 'name' => 'c' }
                   ])
  rescue Kiln::DB::Error => e
    err = e
  end
  name = err ? err.class.to_s.split('::').last : 'none'
  state = err ? err.sqlstate.to_s : ''
  count = count_of(conn, 'SELECT COUNT(*) FROM kiln_p10_copy_dup')
  print "copy_duplicate #{name} #{state} #{count}\n"
  need('duplicate', name == 'UniqueViolation' && state == '23505' && count.zero?)
end

def check_outer(conn)
  state = 'missing'
  raised = false
  begin
    Kiln::DB.transaction do
      result = CopyTx.import([{ 'id' => 1, 'name' => 'a' }])
      state = result.state
      raise 'rollback'
    end
  rescue StandardError
    raised = true
  end
  count = count_of(conn, 'SELECT COUNT(*) FROM kiln_p10_copy_tx')
  print "copy_outer_tx #{state} #{count}\n"
  need('outer', raised && state == 'PENDING_COMMIT' && count.zero?)
end

def check_split(conn)
  rows = []
  i = 0
  while i < 40_000
    rows << { 'id' => i + 1, 'body' => 'x' * 450 }
    i += 1
  end
  CopyBig.import(rows)
  count = count_of(conn, 'SELECT COUNT(*) FROM kiln_p10_copy_big')
  total = count_of(conn, 'SELECT SUM(LENGTH(body)) FROM kiln_p10_copy_big')
  head = conn.exec('SELECT body FROM kiln_p10_copy_big WHERE id = 1', [])[0][0]
  tail = conn.exec('SELECT body FROM kiln_p10_copy_big WHERE id = 40000', [])[0][0]
  print "copy_split #{count} #{total}\n"
  need('split', count == 40_000 && total == 18_000_000 && head.bytesize == 450 && tail.bytesize == 450)
end

def check_fallback(conn)
  binary = (+'').b
  binary << 255
  binary << 0
  binary << 1
  CopyBin.import([{ 'id' => 1, 'b' => binary }])
  got = conn.exec('SELECT b FROM kiln_p10_copy_bin WHERE id = 1', [])[0][0]
  need('fallback', got.b == binary)
  print "copy_fallback insert\n"
end

def stamps_equal(conn)
  sql = 'SELECT COUNT(*) FROM kiln_p10_copy_stamp c JOIN kiln_p10_ins_stamp i ON i.id = c.id ' \
        'WHERE c.created_at = i.created_at AND c.updated_at = i.updated_at'
  count_of(conn, sql)
end

def check_stamps(conn)
  conn.exec("SET TIME ZONE 'Asia/Tokyo'", [])
  Kiln::DB.transaction do
    CopyStamp.import([{ 'id' => 1 }, { 'id' => 2 }], { timestamps: true })
    InsStamp.import([{ 'id' => 1 }, { 'id' => 2 }], { timestamps: true, returning: true })
  end
  same = stamps_equal(conn)
  conn.exec('RESET TIME ZONE', [])
  print "copy_timestamps #{same}\n"
  need('timestamps', same == 2)
end

def interrupted_copy(conn)
  conn.copy_in('COPY kiln_p10_copy_tx (id, name) FROM STDIN', (+"9\tz\n").b, 1)
  'none'
rescue Kiln::DB::Error => e
  e.class.to_s.split('::').last
end

def check_timeout(text)
  locker = open_db(text)
  conn = open_db(text, 1)
  locker.exec('BEGIN', [])
  locker.exec('LOCK TABLE kiln_p10_copy_tx IN ACCESS EXCLUSIVE MODE', [])
  name = interrupted_copy(conn)
  locker.exec('ROLLBACK', [])
  broken = conn.broken?
  conn.close
  locker.close
  print "copy_timeout #{name} broken=#{broken}\n"
  need('copy timeout', name == 'Timeout' && broken)
end

def prepare(conn)
  TABLES.each { |table| conn.exec("DROP TABLE IF EXISTS #{table}", []) }
  cols = 'id INT PRIMARY KEY, s TEXT NULL, n BIGINT NULL, f DOUBLE PRECISION NULL, ' \
         'd NUMERIC(40, 9) NULL, b BOOLEAN NULL'
  conn.exec("CREATE TABLE kiln_p10_copy (#{cols})", [])
  conn.exec("CREATE TABLE kiln_p10_copy_ins (#{cols})", [])
  conn.exec('CREATE TABLE kiln_p10_copy_dup (id INT PRIMARY KEY, name TEXT NOT NULL)', [])
  conn.exec('CREATE TABLE kiln_p10_copy_tx (id INT PRIMARY KEY, name TEXT NOT NULL)', [])
  conn.exec('CREATE TABLE kiln_p10_copy_big (id INT PRIMARY KEY, body TEXT NOT NULL)', [])
  conn.exec('CREATE TABLE kiln_p10_copy_bin (id INT PRIMARY KEY, b BYTEA NULL)', [])
  conn.exec("CREATE TABLE kiln_p10_copy_stamp (#{STAMP_COLS})", [])
  conn.exec("CREATE TABLE kiln_p10_ins_stamp (#{STAMP_COLS})", [])
  CopyVal.define_table(:postgres, 'kiln_p10_copy', %w[id s n f d b], ['id'], 'cv')
  CopyIns.define_table(:postgres, 'kiln_p10_copy_ins', %w[id s n f d b], ['id'], 'ci')
  CopyDup.define_table(:postgres, 'kiln_p10_copy_dup', %w[id name], ['id'], 'cd')
  CopyTx.define_table(:postgres, 'kiln_p10_copy_tx', %w[id name], ['id'], 'ct')
  CopyBig.define_table(:postgres, 'kiln_p10_copy_big', %w[id body], ['id'], 'cg')
  CopyBin.define_table(:postgres, 'kiln_p10_copy_bin', %w[id b], ['id'], 'cb')
  CopyStamp.define_table(:postgres, 'kiln_p10_copy_stamp', %w[id created_at updated_at], ['id'], 'cs')
  InsStamp.define_table(:postgres, 'kiln_p10_ins_stamp', %w[id created_at updated_at], ['id'], 'is')
end

def finish(conn)
  TABLES.each { |table| conn.exec("DROP TABLE IF EXISTS #{table}", []) }
  Kiln::DB::Scope.use(nil)
  conn.close
end

check_text
text = File.read('build/db-runtime/session.env')
conn = open_db(text)
Kiln::DB::Scope.use(conn)
prepare(conn)
check_values(conn)
check_duplicate(conn)
check_outer(conn)
check_split(conn)
check_fallback(conn)
check_stamps(conn)
check_timeout(text)
finish(conn)
print "ok copy_import\n"
