require 'kiln/db'
require 'test/db/support'

Thread.current

Target = Struct.new(:db, :kind, :host_key, :auth_key)

def need(label, cond)
  return if cond

  print "FAILED #{label}\n"
  raise label
end

def open_target(text, target)
  ca = "#{env_line(text, 'KILN_DB_CONFIG_DIR')}/ca.crt"
  Kiln::DB::Conn.open(target.kind, env_line(text, "#{target.host_key}_HOST"),
                      env_line(text, "#{target.host_key}_PORT").to_i, env_line(text, "#{target.auth_key}_USER"),
                      env_line(text, "#{target.auth_key}_PASSWORD"), env_line(text, "#{target.auth_key}_DB"), ca,
                      env_line(text, 'KILN_DB_TLS_NAME'))
end

def step(handle, operation)
  out = Kiln::DB::Native.drive(handle, 1, 1, operation, Kiln::DB::Native.now_ms + 30_000)
  need("step #{operation} #{out[4]}", out[0] == Kiln::DB::Native::STEP_DONE)
end

def old_append(handle, rows, width, count)
  types = Kiln::DB::Native.result_types(handle, 1, 1, width)
  lens = Array.new(width, 0)
  r = 0
  while r < count
    rows << Kiln::DB::Codec.row(Kiln::DB::Native.result_row(handle, 1, 1, r, lens), lens, types, width)
    r += 1
  end
end

def old_chunk_done?(handle, rows)
  meta = Kiln::DB::Native.result_meta(handle, 1, 1)
  old_append(handle, rows, meta[0], meta[1]) if meta[0].positive? && meta[1].positive?
  meta[2] == 1
end

def old_rows(conn, sql)
  handle = conn.handle
  Kiln::DB::Native.set_format(handle, 1, 1, 0, 0)
  Kiln::DB::Native.set_sql(handle, 1, 1, sql)
  step(handle, Kiln::DB::Native::OP_PREPARE) if conn.kind == Kiln::DB::Native::KIND_MY
  step(handle, Kiln::DB::Native::OP_EXEC)
  rows = []
  step(handle, Kiln::DB::Native::OP_DRAIN) until old_chunk_done?(handle, rows)
  rows
end

def same_cell?(left, right)
  return false unless left.class == right.class && left == right
  return true unless left.is_a?(String)

  left.encoding == right.encoding
end

def same_row?(left, right)
  return false unless left.length == right.length

  c = 0
  while c < left.length
    return false unless same_cell?(left[c], right[c])

    c += 1
  end
  true
end

def same_rows?(left, right)
  return false unless left.length == right.length

  r = 0
  while r < left.length
    return false unless same_row?(left[r], right[r])

    r += 1
  end
  true
end

def blob_type(conn) = conn.kind == Kiln::DB::Native::KIND_PG ? 'bytea' : 'LONGBLOB'

def text_type(conn) = conn.kind == Kiln::DB::Native::KIND_PG ? 'text' : 'LONGTEXT'

def mark(conn, index) = conn.kind == Kiln::DB::Native::KIND_PG ? "$#{index}" : '?'

def make_table(conn)
  conn.exec('DROP TABLE IF EXISTS kiln_rb', [])
  conn.exec("CREATE TABLE kiln_rb (id INT PRIMARY KEY, b #{blob_type(conn)}, t #{text_type(conn)}, n INT)", [])
end

def text_for(id)
  return nil if (id % 11).zero?
  return '' if (id % 7).zero?

  "строка-#{id}-🙂"
end

def insert_rows(conn, from, upto, size)
  marks = [mark(conn, 1), mark(conn, 2), mark(conn, 3), mark(conn, 4)].join(', ')
  sql = "INSERT INTO kiln_rb (id, b, t, n) VALUES (#{marks})"
  id = from
  while id <= upto
    blob = size.positive? ? ("\x00\xFF".b * (size / 2)) : "\x00\xFF#{id}".b
    conn.exec(sql, [id, blob, size.positive? ? 'x' * size : text_for(id), id * 3])
    id += 1
  end
end

def wide_sql
  cols = ['id']
  k = 1
  while k < 20
    cols << "id + #{k}"
    k += 1
  end
  "SELECT #{cols.join(', ')} FROM kiln_rb ORDER BY id"
end

def compare(conn, label, sql)
  fresh = conn.exec(sql, [])
  need("#{label} batch equals per-row", same_rows?(fresh, old_rows(conn, sql)))
  fresh.length
end

def check_counts(conn, db)
  make_table(conn)
  sizes = []
  [0, 1, 1000, 3000].each do |count|
    conn.exec('DELETE FROM kiln_rb', [])
    insert_rows(conn, 1, count, 0)
    sizes << compare(conn, "#{db} rows #{count}", 'SELECT id, b, t, n FROM kiln_rb ORDER BY id')
  end
  sizes << compare(conn, "#{db} wide", wide_sql)
  print "#{db} counts #{sizes.join(' ')}\n"
end

def check_big(conn, db)
  conn.exec('DELETE FROM kiln_rb', [])
  insert_rows(conn, 1, 1, 1_048_576)
  one = compare(conn, "#{db} 1MiB", 'SELECT id, b, t, n FROM kiln_rb ORDER BY id')
  conn.exec('DELETE FROM kiln_rb', [])
  insert_rows(conn, 1, 3, 614_400)
  three = compare(conn, "#{db} 3x600KB", 'SELECT id, b, t, n FROM kiln_rb ORDER BY id')
  print "#{db} big #{one} #{three}\n"
end

def streamed_until(conn, sql, stop)
  got = []
  conn.each_row(sql, []) do |row|
    got << row
    break if got.length == stop
  end
  got
end

def refill(conn, count)
  conn.exec('DELETE FROM kiln_rb', [])
  insert_rows(conn, 1, count, 0)
end

def check_stream(conn, db)
  refill(conn, 1000)
  sql = 'SELECT id, b, t, n FROM kiln_rb ORDER BY id'
  whole = conn.exec(sql, [])
  part = streamed_until(conn, sql, 300)
  need("#{db} stream prefix", same_rows?(part, whole.first(300)))
  full = streamed_until(conn, sql, 5000)
  need("#{db} stream full", same_rows?(full, whole))
  print "#{db} stream #{part.length} #{full.length} #{row_count(conn)} broken=#{conn.broken?}\n"
end

def row_count(conn) = conn.exec('SELECT COUNT(*) FROM kiln_rb', [])[0][0].to_s

text = File.read('build/db-runtime/session.env')
targets = [
  Target.new('pg', Kiln::DB::Native::KIND_PG, 'DB_PG17', 'KILN_DB_PG'),
  Target.new('mysql', Kiln::DB::Native::KIND_MY, 'DB_MY', 'KILN_DB_MY'),
  Target.new('mariadb', Kiln::DB::Native::KIND_MY, 'DB_MARIA', 'KILN_DB_MY')
]
targets.each do |target|
  conn = open_target(text, target)
  check_counts(conn, target.db)
  check_big(conn, target.db)
  check_stream(conn, target.db)
  conn.exec('DROP TABLE kiln_rb', [])
  conn.close
end
print "ok row_batch\n"
