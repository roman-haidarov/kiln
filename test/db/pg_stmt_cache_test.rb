require 'kiln/db'
require 'test/db/support'

Thread.current

def line(label, value)
  print "pg #{label} #{value}\n"
end

def need(label, cond)
  return if cond

  print "FAILED #{label}\n"
  raise label
end

def verdict(label, passed, detail)
  line(label, passed ? 'yes' : 'no')
  need("#{label} #{detail}", passed)
end

def open_pg(text, cache)
  ca = "#{env_line(text, 'KILN_DB_CONFIG_DIR')}/ca.crt"
  Kiln::DB::Conn.open(Kiln::DB::Native::KIND_PG, env_line(text, 'DB_PG17_HOST'), env_line(text, 'DB_PG17_PORT').to_i,
                      env_line(text, 'KILN_DB_PG_USER'), env_line(text, 'KILN_DB_PG_PASSWORD'),
                      env_line(text, 'KILN_DB_PG_DB'), ca, env_line(text, 'KILN_DB_TLS_NAME'), statement_cache: cache)
end

def named(conn)
  tag = (Kiln::Runtime.now * 1e9).to_i
  sql = "SELECT count(*) FROM pg_prepared_statements WHERE name LIKE 'kiln_s%' AND #{tag} > 0"
  conn.exec(sql, [])[0][0].to_s.to_i
end

def times(conn, sql, binds, count)
  rows = []
  i = 0
  while i < count
    rows = conn.exec(sql, binds)
    i += 1
  end
  rows
end

def in_transaction(conn, &)
  Kiln::DB::Scope.use(conn)
  begin
    Kiln::DB.transaction(&)
  ensure
    Kiln::DB::Scope.use(nil)
  end
end

def check_first_sighting(text)
  conn = open_pg(text, 32)
  base = named(conn)
  times(conn, 'SELECT 41 AS kiln_pg_first', [], 1)
  once = named(conn)
  times(conn, 'SELECT 41 AS kiln_pg_first', [], 1)
  twice = named(conn)
  conn.close
  verdict('first_sighting', once == base && twice == base + 1, "#{base} #{once} #{twice}")
end

def distinct_twice?(conn, count)
  i = 0
  while i < count
    return false unless times(conn, "SELECT #{i} AS kiln_pg_bound", [], 2)[0][0].to_s == i.to_s

    i += 1
  end
  true
end

def check_session_bound(text)
  conn = open_pg(text, 32)
  rows_ok = distinct_twice?(conn, 100)
  held = named(conn)
  conn.close
  verdict('session_bound', rows_ok && held <= 32, "#{rows_ok} #{held}")
end

def check_disabled(text)
  conn = open_pg(text, 0)
  times(conn, 'SELECT 5 AS kiln_pg_off', [], 5)
  held = named(conn)
  conn.close
  verdict('disabled', held.zero?, held.to_s)
end

def bind_ok?(conn, value)
  rows = conn.exec('SELECT $1::int8 + 1, $2::text, $3::bytea', [value, "v#{value}", "\x00\xFF#{value}".b])
  rows[0][0].to_s == (value + 1).to_s && rows[0][1].to_s == "v#{value}" && rows[0][2] == "\x00\xFF#{value}".b
end

def binds_ok?(conn, count)
  i = 0
  while i < count
    return false unless bind_ok?(conn, (i * 1_000_003) - 7)

    i += 1
  end
  true
end

def null_binds_ok?(conn)
  conn.exec('SELECT $1::text IS NULL', [nil])
  null_hit = conn.exec('SELECT $1::text IS NULL', [nil])[0][0]
  null_hit == true && conn.exec('SELECT $1::text IS NULL', ['x'])[0][0] == false
end

def check_binds(text)
  conn = open_pg(text, 32)
  ok = binds_ok?(conn, 50) && null_binds_ok?(conn)
  conn.close
  verdict('binds', ok, '')
end

def reset_table(conn)
  conn.exec('DROP TABLE IF EXISTS kiln_pg_alter', [])
  conn.exec('CREATE TABLE kiln_pg_alter (id int PRIMARY KEY, name text NOT NULL)', [])
  conn.exec("INSERT INTO kiln_pg_alter VALUES (1, 'a')", [])
end

def width(conn)
  conn.exec('SELECT * FROM kiln_pg_alter WHERE id = 1', [])[0].length
end

def width_after_alter_in_tx(conn)
  inside = 0
  in_transaction(conn) do |tx|
    tx.exec('ALTER TABLE kiln_pg_alter ADD COLUMN more int DEFAULT 8', [])
    inside = width(tx)
  end
  inside
end

def check_same_session_alter(text)
  conn = open_pg(text, 32)
  reset_table(conn)
  times(conn, 'SELECT * FROM kiln_pg_alter WHERE id = 1', [], 3)
  conn.exec('ALTER TABLE kiln_pg_alter ADD COLUMN extra int DEFAULT 7', [])
  outside = width(conn)
  inside = width_after_alter_in_tx(conn)
  conn.exec('DROP TABLE kiln_pg_alter', [])
  conn.close
  verdict('same_session_alter', outside == 3 && inside == 4, "#{outside} #{inside}")
end

def tx_width_state(conn)
  in_transaction(conn) { |tx| width(tx) }
  'none'
rescue Kiln::DB::Error => e
  e.sqlstate.to_s
end

def other_alter_results(conn, other)
  times(conn, 'SELECT * FROM kiln_pg_alter WHERE id = 1', [], 3)
  other.exec('ALTER TABLE kiln_pg_alter ADD COLUMN extra int DEFAULT 7', [])
  outside = width(conn)
  times(conn, 'SELECT * FROM kiln_pg_alter WHERE id = 1', [], 2)
  other.exec('ALTER TABLE kiln_pg_alter ADD COLUMN more int DEFAULT 8', [])
  state = tx_width_state(conn)
  [outside, state, width(conn)]
end

def check_other_session_alter(text)
  conn = open_pg(text, 32)
  other = open_pg(text, 0)
  reset_table(other)
  outside, state, after = other_alter_results(conn, other)
  other.exec('DROP TABLE kiln_pg_alter', [])
  other.close
  conn.close
  verdict('other_session_alter', outside == 3 && state == '0A000' && after == 4, "#{outside} #{state} #{after}")
end

def after_deallocate_in_tx(conn)
  times(conn, 'SELECT 9 AS kiln_pg_dealloc', [], 3)
  conn.exec('DEALLOCATE ALL', [])
  inside = ''
  in_transaction(conn) { |tx| inside = tx.exec('SELECT 9 AS kiln_pg_dealloc', [])[0][0].to_s }
  inside
end

def after_hidden_deallocate(conn)
  times(conn, 'SELECT 9 AS kiln_pg_dealloc', [], 2)
  conn.exec('/* hidden */ DEALLOCATE ALL', [])
  conn.exec('SELECT 9 AS kiln_pg_dealloc', [])[0][0].to_s
end

def check_deallocate(text)
  conn = open_pg(text, 32)
  inside = after_deallocate_in_tx(conn)
  hidden = after_hidden_deallocate(conn)
  conn.close
  verdict('deallocate', inside == '9' && hidden == '9', "#{inside} #{hidden}")
end

def streamed(conn, sql)
  seen = 0
  conn.each_row(sql, []) { |row| seen += 1 if row[0].to_s == (seen + 1).to_s }
  seen
end

def check_stream(text)
  conn = open_pg(text, 32)
  sql = 'SELECT g FROM generate_series(1, 3000) g'
  total = streamed(conn, sql) + streamed(conn, sql) + streamed(conn, sql)
  held = named(conn)
  conn.close
  verdict('stream', total == 9000 && held >= 1, "#{total} #{held}")
end

def pipelined_values(conn)
  conn.pipeline_begin
  3.times { conn.pipeline_exec('SELECT 77 AS kiln_pg_pipe', []) }
  conn.pipeline_sync
  values = [conn.pipeline_read, conn.pipeline_read, conn.pipeline_read]
  conn.pipeline_sync_read
  conn.pipeline_finish
  values
end

def check_pipeline(text)
  conn = open_pg(text, 32)
  base = named(conn)
  values = pipelined_values(conn)
  after = named(conn)
  conn.close
  ok = after == base && values.all? { |rows| rows[0][0].to_s == '77' }
  verdict('pipeline', ok, "#{base} #{after}")
end

text = File.read('build/db-runtime/session.env')
check_first_sighting(text)
check_session_bound(text)
check_disabled(text)
check_binds(text)
check_same_session_alter(text)
check_other_session_alter(text)
check_deallocate(text)
check_stream(text)
check_pipeline(text)
print "ok pg_stmt_cache\n"
