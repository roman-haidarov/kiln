require 'kiln/db'
require 'test/db/support'

Thread.current

class PluckRow < Kiln::DB::Model
end

def need(label, cond)
  return if cond

  print "FAILED #{label}\n"
  raise label
end

def open_db(text, host_key, auth_key, kind)
  ca = "#{env_line(text, 'KILN_DB_CONFIG_DIR')}/ca.crt"
  Kiln::DB::Conn.open(kind, env_line(text, "#{host_key}_HOST"), env_line(text, "#{host_key}_PORT").to_i,
                      env_line(text, "#{auth_key}_USER"), env_line(text, "#{auth_key}_PASSWORD"),
                      env_line(text, "#{auth_key}_DB"), ca, env_line(text, 'KILN_DB_TLS_NAME'))
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

def list_same?(left, right)
  return false unless left.length == right.length

  i = 0
  while i < left.length
    item = left[i]
    other = right[i]
    if item.is_a?(Array)
      return false unless row_same?(item, other)
    else
      return false unless cell_same?(item, other)
    end
    i += 1
  end
  true
end

def cell_line(value)
  return "#{value.class} #{value.inspect} #{value.encoding}" if value.is_a?(String)
  if value.is_a?(Kiln::DB::ExactDecimal) || value.is_a?(Kiln::DB::UInt64Value) || value.is_a?(Kiln::DB::Int64Value)
    return "#{value.class} #{value}"
  end

  "#{value.class} #{value.inspect}"
end

def show_rows(db, label, rows)
  r = 0
  while r < rows.length
    c = 0
    while c < rows[r].length
      print "#{db} #{label} r#{r} c#{c} #{cell_line(rows[r][c])}\n"
      c += 1
    end
    r += 1
  end
end

def show_list(db, label, values)
  i = 0
  while i < values.length
    print "#{db} #{label} i#{i} #{cell_line(values[i])}\n"
    i += 1
  end
end

def thrice(conn, db, label, sql)
  first = conn.exec(sql, [])
  second = conn.exec(sql, [])
  third = conn.exec(sql, [])
  need("#{db} #{label} stable", rows_same?(first, second) && rows_same?(second, third))
  streamed = []
  conn.each_row(sql, []) { |row| streamed << row }
  need("#{db} #{label} stream", rows_same?(streamed, third))
  print "ok stream #{db} #{label}\n"
  show_rows(db, label, third)
end

def my_schema(conn)
  conn.exec('DROP TABLE IF EXISTS kiln_p10_td', [])
  conn.exec('DROP TABLE IF EXISTS kiln_p10_pluck', [])
  conn.exec(
    'CREATE TABLE kiln_p10_td (id INT PRIMARY KEY, ti TINYINT, tiu TINYINT UNSIGNED, ' \
    'si SMALLINT, siu SMALLINT UNSIGNED, mi MEDIUMINT, miu MEDIUMINT UNSIGNED, ' \
    'ii INT, iiu INT UNSIGNED, bi BIGINT, biu BIGINT UNSIGNED, d DOUBLE, f FLOAT, ' \
    'decv DECIMAL(30,10), yr YEAR, bits BIT(8), flag TINYINT(1))', []
  )
  conn.exec(
    'CREATE TABLE kiln_p10_pluck (id INT PRIMARY KEY, n INT, f DOUBLE, t VARCHAR(40), ' \
    'b TINYINT(1), z INT)', []
  )
end

def my_insert_bounds(conn)
  conn.exec(
    'INSERT INTO kiln_p10_td (id, ti, tiu, si, siu, mi, miu, ii, iiu, bi, biu, d, f, decv, yr, bits, flag) VALUES ' \
    '(1, -128, 0, -32768, 0, -8388608, 0, -2147483648, 0, CAST(\'-9223372036854775808\' AS SIGNED), 0, ' \
    '0.1, 1.1, 12345678901234567890.1234567890, 2024, b\'10100101\', 1)', []
  )
  conn.exec(
    'INSERT INTO kiln_p10_td (id, ti, tiu, si, siu, mi, miu, ii, iiu, bi, biu, d, f, decv, yr, bits, flag) VALUES ' \
    '(2, 127, 255, 32767, 65535, 8388607, 16777215, 2147483647, 4294967295, 9223372036854775807, ' \
    'CAST(\'18446744073709551615\' AS UNSIGNED), CAST(-0e0 AS DOUBLE), 1.1, ' \
    '-12345678901234567890.1234567890, 1901, b\'11111111\', 0)', []
  )
end

def my_insert_rest(conn)
  conn.exec(
    'INSERT INTO kiln_p10_td (id, d, f) VALUES (3, 1e308, 1.1), (4, 5e-324, 1.1)', []
  )
  conn.exec('INSERT INTO kiln_p10_td (id) VALUES (5)', [])
  conn.exec(
    'INSERT INTO kiln_p10_pluck (id, n, f, t, b, z) VALUES ' \
    '(1, -2147483648, 1.5, \'hello\', 1, 10), ' \
    '(2, 7, CAST(-0e0 AS DOUBLE), \'café🙂\', 0, NULL), ' \
    '(3, NULL, NULL, NULL, NULL, NULL)', []
  )
end

def pg_schema(conn)
  conn.exec('DROP TABLE IF EXISTS kiln_p10_td', [])
  conn.exec('DROP TABLE IF EXISTS kiln_p10_pluck', [])
  conn.exec(
    'CREATE TABLE kiln_p10_td (id INT PRIMARY KEY, i2 INT2, i4 INT4, i8 INT8, f8 FLOAT8, ' \
    'f4 FLOAT4, flag BOOLEAN, num NUMERIC, raw BYTEA, txt TEXT, vc VARCHAR(40))', []
  )
  conn.exec(
    'CREATE TABLE kiln_p10_pluck (id INT PRIMARY KEY, n INT, f FLOAT8, t TEXT, b BOOLEAN, z INT)', []
  )
end

def pg_insert_bounds(conn)
  conn.exec(
    'INSERT INTO kiln_p10_td (id, i2, i4, i8, f8, f4, flag, num, raw, txt, vc) VALUES ' \
    '(1, -32768, -2147483648, -9223372036854775808, 0.1, 1.1::float4, true, ' \
    '12345678901234567890.1234567890, decode(\'00ff\', \'hex\'), \'café🙂\', \'varchar\'), ' \
    '(2, 32767, 2147483647, 9223372036854775807, \'-0\'::float8, 1.1::float4, false, ' \
    '-12345678901234567890.1234567890, decode(\'00\', \'hex\'), \'\', \'v\')', []
  )
end

def pg_insert_special(conn)
  conn.exec(
    'INSERT INTO kiln_p10_td (id, f8, f4, flag) VALUES ' \
    '(3, \'NaN\'::float8, 1.1::float4, true), ' \
    '(4, \'Infinity\'::float8, 1.1::float4, false), ' \
    '(5, \'-Infinity\'::float8, 1.1::float4, true)', []
  )
  conn.exec('INSERT INTO kiln_p10_td (id) VALUES (6)', [])
  conn.exec(
    'INSERT INTO kiln_p10_pluck (id, n, f, t, b, z) VALUES ' \
    '(1, -2147483648, 1.5, \'hello\', true, 10), ' \
    '(2, 7, \'-0\'::float8, \'café🙂\', false, NULL), ' \
    '(3, NULL, NULL, NULL, NULL, NULL)', []
  )
end

MY_SQL = 'SELECT ti, tiu, si, siu, mi, miu, ii, iiu, bi, biu, d, f, decv, yr, bits, flag ' \
         'FROM kiln_p10_td ORDER BY id'.freeze
PG_TYPED = 'SELECT i2, i4, i8, f8, flag, txt, vc, raw FROM kiln_p10_td ORDER BY id'.freeze
PG_MIXED = 'SELECT i4, f4, num FROM kiln_p10_td ORDER BY id'.freeze

def check_my(conn, db)
  my_schema(conn)
  my_insert_bounds(conn)
  my_insert_rest(conn)
  thrice(conn, db, 'types', MY_SQL)
end

def legacy_rows(conn, count)
  handle = conn.handle
  width = Kiln::DB::Native.result_meta(handle, 1, 1)[0]
  types = Kiln::DB::Native.result_types(handle, 1, 1, width)
  lens = Array.new(width + 1, 0)
  rows = []
  r = 0
  while r < count
    rows << Kiln::DB::Codec.row(Kiln::DB::Native.result_row(handle, 1, 1, r, lens), lens, types, width)
    r += 1
  end
  rows
end

def check_text_export(conn)
  rows = conn.exec(PG_TYPED, [])
  need('pg text export', rows_same?(legacy_rows(conn, rows.length), rows))
  bytea = Kiln::DB::Native.result_bytes(conn.handle, 1, 1, 0, 7)[0]
  print "ok text_export pg #{bytea.inspect}\n"
end

def check_pg(conn)
  pg_schema(conn)
  pg_insert_bounds(conn)
  pg_insert_special(conn)
  thrice(conn, 'pg', 'typed', PG_TYPED)
  thrice(conn, 'pg', 'mixed', PG_MIXED)
  check_text_export(conn)
end

def check_pluck(db)
  PluckRow.define_table(db == 'pg' ? :postgres : :mysql, 'kiln_p10_pluck', %w[id n f t b z], ['id'], 'p')
  %w[n f t b z].each do |name|
    col = PluckRow.col(name)
    rel = PluckRow.all.order(PluckRow.col('id').asc)
    first = rel.pluck(col)
    rel.pluck(col)
    got = rel.pluck(col)
    raw = rel.project([col]).run(:rows).map { |row| row[0] }
    need("#{db} pluck #{name}", list_same?(got, raw) && list_same?(first, got))
    show_list(db, "pluck #{name}", got)
  end
  multi = PluckRow.all.order(PluckRow.col('id').asc).pluck(PluckRow.col('n'), PluckRow.col('t'))
  rows = PluckRow.all.order(PluckRow.col('id').asc).project([PluckRow.col('n'), PluckRow.col('t')]).run(:rows)
  need("#{db} pluck multi", list_same?(multi, rows) && multi[0].length == 2)
  print "ok pluck #{db}\n"
end

def finish(conn)
  conn.exec('DROP TABLE IF EXISTS kiln_p10_td', [])
  conn.exec('DROP TABLE IF EXISTS kiln_p10_pluck', [])
  Kiln::DB::Scope.use(nil)
  conn.close
end

def run_engine(text, db, host_key, auth_key, kind)
  conn = open_db(text, host_key, auth_key, kind)
  Kiln::DB::Scope.use(conn)
  kind == Kiln::DB::Native::KIND_PG ? check_pg(conn) : check_my(conn, db)
  check_pluck(db)
  finish(conn)
end

text = File.read('build/db-runtime/session.env')
run_engine(text, 'pg', 'DB_PG17', 'KILN_DB_PG', Kiln::DB::Native::KIND_PG)
run_engine(text, 'mysql', 'DB_MY', 'KILN_DB_MY', Kiln::DB::Native::KIND_MY)
run_engine(text, 'mariadb', 'DB_MARIA', 'KILN_DB_MY', Kiln::DB::Native::KIND_MY)
print "ok typed_decode\n"
