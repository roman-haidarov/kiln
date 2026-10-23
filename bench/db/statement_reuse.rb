require 'kiln/db'
require 'test/db/support'

Thread.current

SQL = 'SELECT u.id, u.name, u.score FROM kiln_probe_user u WHERE u.id = 5 AND u.score > 1 ORDER BY u.id LIMIT 10'.freeze
REPEATS = 2000
UNIQUE = 500

def now = Kiln::Runtime.now

def micros(total, count) = (total / count * 1e6).round(1).to_s

def drain(handle)
  loop do
    meta = Kiln::DB::Native.result_meta(handle, 1, 1)
    break if meta[2] == 1

    out = Kiln::DB::Native.drive(handle, 1, 1, Kiln::DB::Native::OP_DRAIN, Kiln::DB::Native.now_ms + 15_000)
    raise 'drain' unless out[0] == Kiln::DB::Native::STEP_DONE
  end
end

def step(handle, operation)
  out = Kiln::DB::Native.drive(handle, 1, 1, operation, Kiln::DB::Native.now_ms + 15_000)
  raise "step #{operation} #{out[4]}" unless out[0] == Kiln::DB::Native::STEP_DONE
end

def prepare_and_exec(handle)
  t = now
  i = 0
  while i < REPEATS
    step(handle, Kiln::DB::Native::OP_PREPARE)
    step(handle, Kiln::DB::Native::OP_EXEC)
    drain(handle)
    i += 1
  end
  now - t
end

def exec_prepared(handle)
  step(handle, Kiln::DB::Native::OP_PREPARE)
  t = now
  i = 0
  while i < REPEATS
    step(handle, Kiln::DB::Native::OP_EXEC)
    drain(handle)
    i += 1
  end
  now - t
end

def conn_exec(conn)
  t = now
  i = 0
  while i < REPEATS
    conn.exec(SQL, [])
    i += 1
  end
  now - t
end

def unique_exec(conn)
  t = now
  i = 0
  while i < UNIQUE
    conn.exec("SELECT u.id, u.name FROM kiln_probe_user u WHERE u.score > #{i} LIMIT 10", [])
    i += 1
  end
  now - t
end

def probe(label, conn)
  handle = conn.handle
  Kiln::DB::Native.set_format(handle, 1, 1, 0, 0)
  Kiln::DB::Native.set_sql(handle, 1, 1, SQL)
  both = prepare_and_exec(handle)
  reuse = exec_prepared(handle)
  orm = conn_exec(conn)
  unique = unique_exec(conn)
  print "#{label} prepare_exec_us #{micros(both, REPEATS)} exec_prepared_us #{micros(reuse, REPEATS)} "
  print "conn_exec_us #{micros(orm, REPEATS)} unique_exec_us #{micros(unique, UNIQUE)}\n"
end

def open_conn(text, kind, host_key, auth_key)
  ca = "#{env_line(text, 'KILN_DB_CONFIG_DIR')}/ca.crt"
  Kiln::DB::Conn.open(kind, env_line(text, "#{host_key}_HOST"), env_line(text, "#{host_key}_PORT").to_i,
                      env_line(text, "#{auth_key}_USER"), env_line(text, "#{auth_key}_PASSWORD"),
                      env_line(text, "#{auth_key}_DB"), ca, env_line(text, 'KILN_DB_TLS_NAME'))
end

def seed(conn)
  conn.exec('DROP TABLE IF EXISTS kiln_probe_user', [])
  conn.exec('CREATE TABLE kiln_probe_user (id INT PRIMARY KEY, name VARCHAR(40), score INT)', [])
  conn.exec("INSERT INTO kiln_probe_user VALUES (1, 'ada', 3), (2, 'bea', 4), (5, 'cy', 7)", [])
end

text = File.read('build/db-runtime/session.env')
targets = [
  ['pg', Kiln::DB::Native::KIND_PG, 'DB_PG17', 'KILN_DB_PG'],
  ['mysql', Kiln::DB::Native::KIND_MY, 'DB_MY', 'KILN_DB_MY'],
  ['mariadb', Kiln::DB::Native::KIND_MY, 'DB_MARIA', 'KILN_DB_MY']
]
i = 0
while i < targets.length
  t = targets[i]
  conn = open_conn(text, t[1], t[2], t[3])
  seed(conn)
  probe(t[0], conn)
  probe(t[0], conn)
  conn.exec('DROP TABLE kiln_probe_user', [])
  conn.close
  i += 1
end
print "ok statement_reuse\n"
