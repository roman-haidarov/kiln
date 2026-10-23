require 'kiln/db'
require 'test/db/support'

def need(label, cond)
  return if cond

  print label
  print "\n"
  raise label
end

def later(ms)
  Kiln::DB::Native.now_ms + ms
end

def must(handle, op, ms, label)
  out = Kiln::DB::Native.drive(handle, 1, 1, op, later(ms))
  return out if out[0] == Kiln::DB::Native::STEP_DONE

  print label
  print ' '
  print out[0]
  print ' '
  print out[4]
  print "\n"
  raise label
end

def exec_sql(handle, sql, label)
  need(label, Kiln::DB::Native.set_sql(handle, 1, 1, sql) == Kiln::DB::Native::OK)
  must(handle, Kiln::DB::Native::OP_EXEC, 5000, label)
end

def prepare_sql(handle, sql, label)
  need(label, Kiln::DB::Native.set_sql(handle, 1, 1, sql) == Kiln::DB::Native::OK)
  must(handle, Kiln::DB::Native::OP_PREPARE, 5000, label)
end

def count_rows(handle, label)
  total = 0
  guard = 0
  while guard < 20
    meta = Kiln::DB::Native.result_meta(handle, 1, 1)
    total += meta[1]
    break if meta[2] == 1

    must(handle, Kiln::DB::Native::OP_DRAIN, 5000, label)
    guard += 1
  end
  need(label, guard < 20)
  total
end

def cell(handle, col)
  Kiln::DB::Native.result_bytes(handle, 1, 1, 0, col)
end

def open_db(kind, host, port, user, password, database, ca_path, tls_name, label)
  opened = Kiln::DB::Native.open_conn(kind, 1, 1)
  need(label, opened[0] != 0 && opened[1] == Kiln::DB::Native::OK)
  handle = opened[0]
  endpoint = Kiln::DB::Endpoint.new(host, port, [user, password, database])
  endpoint.secure(Kiln::DB::Native::SSL_VERIFY_FULL, ca_path, tls_name)
  rc = Kiln::DB::Native.connect_params(handle, 1, 1, endpoint)
  need(label, rc == Kiln::DB::Native::OK)
  must(handle, Kiln::DB::Native::OP_CONNECT, 5000, label)
  handle
end

def check_nul(handle, kind, label)
  if kind == Kiln::DB::Native::KIND_PG
    need(label, Kiln::DB::Native.set_format(handle, 1, 1, 1, 0) == Kiln::DB::Native::OK)
    prepare_sql(handle, 'SELECT $1::bytea, $2::bytea', label)
  else
    need(label, Kiln::DB::Native.set_format(handle, 1, 1, 0, 0) == Kiln::DB::Native::OK)
    prepare_sql(handle, 'SELECT ?, ?', label)
  end
  need(label, Kiln::DB::Native.bind_bytes(handle, [1, 1], 0, [97, 0, 98], [0, 1]) == Kiln::DB::Native::OK)
  need(label, Kiln::DB::Native.bind_bytes(handle, [1, 1], 1, nil, [1, 1]) == Kiln::DB::Native::OK)
  must(handle, Kiln::DB::Native::OP_EXEC, 5000, label)
  got = cell(handle, 0)
  need(label, got[1].zero? && got[2] == 3)
  need(label, got[0].bytesize == 3 && got[0][0].ord == 97 && got[0][1].ord.zero? && got[0][2].ord == 98)
  other = cell(handle, 1)
  need(label, other[1] == 1)
  must(handle, Kiln::DB::Native::OP_DRAIN, 5000, label)
  need(label, Kiln::DB::Native.set_format(handle, 1, 1, 0, 0) == Kiln::DB::Native::OK)
end

def check_chunk(handle, kind, label)
  if kind == Kiln::DB::Native::KIND_PG
    need(label, Kiln::DB::Native.set_format(handle, 1, 1, 0, 2) == Kiln::DB::Native::OK)
    prepare_sql(handle, 'SELECT g FROM generate_series(1,5) g', label)
  else
    prepare_sql(handle, 'WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM s WHERE n < 5) SELECT n FROM s',
                label)
  end
  must(handle, Kiln::DB::Native::OP_EXEC, 5000, label)
  need(label, count_rows(handle, label) == 5)
  need(label, Kiln::DB::Native.set_format(handle, 1, 1, 0, 0) == Kiln::DB::Native::OK)
end

def check_rollback(handle, kind, label)
  exec_sql(handle, 'DROP TABLE IF EXISTS kiln_gate_a', label)
  if kind == Kiln::DB::Native::KIND_PG
    exec_sql(handle, 'CREATE TABLE kiln_gate_a (b bytea)', label)
    must(handle, Kiln::DB::Native::OP_BEGIN, 5000, label)
    prepare_sql(handle, 'INSERT INTO kiln_gate_a (b) VALUES ($1::bytea)', label)
  else
    exec_sql(handle, 'CREATE TABLE kiln_gate_a (b VARBINARY(16)) ENGINE=InnoDB', label)
    must(handle, Kiln::DB::Native::OP_BEGIN, 5000, label)
    prepare_sql(handle, 'INSERT INTO kiln_gate_a (b) VALUES (?)', label)
  end
  need(label, Kiln::DB::Native.bind_bytes(handle, [1, 1], 0, [97], [0, 1]) == Kiln::DB::Native::OK)
  must(handle, Kiln::DB::Native::OP_EXEC, 5000, label)
  must(handle, Kiln::DB::Native::OP_ROLLBACK, 5000, label)
  prepare_sql(handle, 'SELECT COUNT(*) FROM kiln_gate_a', label)
  must(handle, Kiln::DB::Native::OP_EXEC, 5000, label)
  got = cell(handle, 0)
  need(label, got[1].zero? && got[0] == '0')
  must(handle, Kiln::DB::Native::OP_DRAIN, 5000, label)
  exec_sql(handle, 'DROP TABLE IF EXISTS kiln_gate_a', label)
end

def check_cancel(handle, kind, host, port, user, password, database, ca_path, tls_name, label)
  started = Kiln::DB::Native.now_ms
  if kind == Kiln::DB::Native::KIND_PG
    need(label, Kiln::DB::Native.set_sql(handle, 1, 1, 'SELECT pg_sleep(30)') == Kiln::DB::Native::OK)
    slept = Kiln::DB::Native.drive(handle, 1, 1, Kiln::DB::Native::OP_EXEC, later(300))
    need(label, slept[0] == Kiln::DB::Native::STEP_ERR && slept[4] == Kiln::DB::Native::TIMEOUT)
    must(handle, Kiln::DB::Native::OP_CANCEL, 5000, label)
  else
    prepare_sql(handle, 'SELECT SLEEP(30)', label)
    slept = Kiln::DB::Native.drive(handle, 1, 1, Kiln::DB::Native::OP_EXEC, later(300))
    need(label, slept[0] == Kiln::DB::Native::STEP_ERR && slept[4] == Kiln::DB::Native::TIMEOUT)
    Kiln::DB::Native.drive(handle, 1, 1, Kiln::DB::Native::OP_CANCEL, later(1000))
    ident = Kiln::DB::Native.peer_id(handle, 1, 1)
    need(label, ident.positive?)
    killer = open_db(kind, host, port, user, password, database, ca_path, tls_name, label)
    exec_sql(killer, "KILL QUERY #{ident}", label)
    Kiln::DB::Native.drive(handle, 1, 1, Kiln::DB::Native::OP_EXEC, later(5000))
    must(killer, Kiln::DB::Native::OP_CLOSE, 5000, label)
  end
  prepare_sql(handle, 'SELECT 1', label)
  must(handle, Kiln::DB::Native::OP_EXEC, 5000, label)
  must(handle, Kiln::DB::Native::OP_DRAIN, 5000, label)
  need(label, Kiln::DB::Native.now_ms - started < 5000)
end

def check_stale(handle, kind, host, port, user, password, database, ca_path, tls_name, label)
  must(handle, Kiln::DB::Native::OP_CLOSE, 5000, label)
  out = Kiln::DB::Native.drive(handle, 1, 1, Kiln::DB::Native::OP_EXEC, later(1000))
  need(label, out[0] == Kiln::DB::Native::STEP_ERR && out[4] == Kiln::DB::Native::STALE)
  fresh = open_db(kind, host, port, user, password, database, ca_path, tls_name, label)
  prepare_sql(fresh, 'SELECT 1', label)
  must(fresh, Kiln::DB::Native::OP_EXEC, 5000, label)
  must(fresh, Kiln::DB::Native::OP_DRAIN, 5000, label)
  must(fresh, Kiln::DB::Native::OP_CLOSE, 5000, label)
end

def run_db(name, kind, host, port, user, password, database, ca_path, tls_name)
  handle = open_db(kind, host, port, user, password, database, ca_path, tls_name, "#{name}-tls")
  print name
  print "-tls\n"
  check_nul(handle, kind, "#{name}-nul")
  print name
  print "-nul\n"
  check_chunk(handle, kind, "#{name}-chunk")
  print name
  print "-chunk 5\n"
  check_rollback(handle, kind, "#{name}-rollback")
  print name
  print "-rollback 0\n"
  check_cancel(handle, kind, host, port, user, password, database, ca_path, tls_name, "#{name}-cancel")
  print name
  print "-cancel\n"
  check_stale(handle, kind, host, port, user, password, database, ca_path, tls_name, "#{name}-stale")
  print name
  print "-stale\n"
  print name
  print "-reconnect\n"
end

def gc_stress(host, port, user, password, database, ca_path, tls_name)
  flag = [0]
  counter = [0]
  worker = Thread.new do
    while flag[0].zero?
      blob = String.new
      blob << 'x'
      counter[0] += 1
    end
  end
  handle = open_db(Kiln::DB::Native::KIND_PG, host, port, user, password, database, ca_path, tls_name, 'gc')
  need('gc', Kiln::DB::Native.set_sql(handle, 1, 1, 'SELECT pg_sleep(0.5)') == Kiln::DB::Native::OK)
  must(handle, Kiln::DB::Native::OP_EXEC, 5000, 'gc')
  seen = counter[0]
  flag[0] = 1
  worker.join
  must(handle, Kiln::DB::Native::OP_CLOSE, 5000, 'gc')
  if seen.positive?
    print "gc-moved\n"
  else
    print "gc-stuck\n"
    raise 'gc-stuck'
  end
end

path = 'build/db-runtime/session.env'
unless File.exist?(path)
  print "blocked gate-a\n"
  exit 0
end

text = File.read(path)
ca_path = "#{env_line(text, 'KILN_DB_CONFIG_DIR')}/ca.crt"
tls_name = env_line(text, 'KILN_DB_TLS_NAME')
pg_user = env_line(text, 'KILN_DB_PG_USER')
pg_password = env_line(text, 'KILN_DB_PG_PASSWORD')
pg_db = env_line(text, 'KILN_DB_PG_DB')
my_user = env_line(text, 'KILN_DB_MY_USER')
my_password = env_line(text, 'KILN_DB_MY_PASSWORD')
my_db = env_line(text, 'KILN_DB_MY_DB')
need('configured', Kiln::DB::Native.configure == Kiln::DB::Native::OK)
need('configured', Kiln::DB::Native.load_kind(Kiln::DB::Native::KIND_PG) == Kiln::DB::Native::OK)
need('configured', Kiln::DB::Native.load_kind(Kiln::DB::Native::KIND_MY) == Kiln::DB::Native::OK)
need('configured', Kiln::DB::Native.client_version(Kiln::DB::Native::KIND_PG) >= 170_000)
need('configured', Kiln::DB::Native.client_version(Kiln::DB::Native::KIND_MY) >= 30_100)
print "configured\n"
run_db('pg17', Kiln::DB::Native::KIND_PG, env_line(text, 'DB_PG17_HOST'), env_line(text, 'DB_PG17_PORT').to_i, pg_user,
       pg_password, pg_db, ca_path, tls_name)
run_db('pg18', Kiln::DB::Native::KIND_PG, env_line(text, 'DB_PG18_HOST'), env_line(text, 'DB_PG18_PORT').to_i, pg_user,
       pg_password, pg_db, ca_path, tls_name)
run_db('mysql84', Kiln::DB::Native::KIND_MY, env_line(text, 'DB_MY_HOST'), env_line(text, 'DB_MY_PORT').to_i, my_user,
       my_password, my_db, ca_path, tls_name)
run_db('mariadb114', Kiln::DB::Native::KIND_MY, env_line(text, 'DB_MARIA_HOST'), env_line(text, 'DB_MARIA_PORT').to_i,
       my_user, my_password, my_db, ca_path, tls_name)
gc_stress(env_line(text, 'DB_PG17_HOST'), env_line(text, 'DB_PG17_PORT').to_i, pg_user, pg_password, pg_db, ca_path,
          tls_name)
print "ok gate-a\n"
