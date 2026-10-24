require 'kiln/db'
require 'test/db/support'

Thread.current

ROWS = 20_000
ROUNDS = 5

class ProbeItem < Kiln::DB::Model
end

def now = Kiln::Runtime.now

def open_conn(text, kind, host_key, auth_key)
  ca = "#{env_line(text, 'KILN_DB_CONFIG_DIR')}/ca.crt"
  Kiln::DB::Conn.open(kind, env_line(text, "#{host_key}_HOST"), env_line(text, "#{host_key}_PORT").to_i,
                      env_line(text, "#{auth_key}_USER"), env_line(text, "#{auth_key}_PASSWORD"),
                      env_line(text, "#{auth_key}_DB"), ca, env_line(text, 'KILN_DB_TLS_NAME'))
end

def rows_for(offset)
  rows = []
  i = 0
  while i < ROWS
    rows << { 'id' => offset + i, 'name' => "item-#{i}", 'v' => i % 1000 }
    i += 1
  end
  rows
end

def reset(conn)
  conn.exec('DROP TABLE IF EXISTS kiln_probe_item', [])
  conn.exec('CREATE TABLE kiln_probe_item (id INT PRIMARY KEY, name VARCHAR(40), v INT NOT NULL)', [])
  ProbeItem.define_table(conn.dialect, 'kiln_probe_item', %w[id name v], ['id'], 'pi')
end

def import_once(conn)
  reset(conn)
  rows = rows_for(1)
  t = now
  result = ProbeItem.import(rows)
  spent = now - t
  raise 'import' unless result.length == ROWS

  spent
end

def import_us(conn)
  total = 0.0
  k = 0
  while k < ROUNDS
    total += import_once(conn)
    k += 1
  end
  total / (ROUNDS * ROWS) * 1e6
end

def pluck_us
  ProbeItem.all.pluck(ProbeItem.col('v'))
  t = now
  k = 0
  while k < ROUNDS
    got = ProbeItem.all.pluck(ProbeItem.col('v'))
    raise 'pluck' unless got.length == ROWS

    k += 1
  end
  (now - t) / (ROUNDS * ROWS) * 1e9
end

def drain_all(handle)
  meta = Kiln::DB::Native.result_meta(handle, 1, 1)
  until meta[2] == 1
    Kiln::DB::Native.drive(handle, 1, 1, Kiln::DB::Native::OP_DRAIN, Kiln::DB::Native.now_ms + 15_000)
    meta = Kiln::DB::Native.result_meta(handle, 1, 1)
  end
end

def floor_once(conn)
  handle = conn.handle
  Kiln::DB::Native.set_format(handle, 1, 1, 0, 0)
  Kiln::DB::Native.set_sql(handle, 1, 1, 'SELECT v FROM kiln_probe_item')
  if conn.kind == Kiln::DB::Native::KIND_MY
    Kiln::DB::Native.drive(handle, 1, 1, Kiln::DB::Native::OP_PREPARE, Kiln::DB::Native.now_ms + 15_000)
  end
  Kiln::DB::Native.drive(handle, 1, 1, Kiln::DB::Native::OP_EXEC, Kiln::DB::Native.now_ms + 15_000)
  drain_all(handle)
end

def floor_ns(conn)
  floor_once(conn)
  t = now
  k = 0
  while k < ROUNDS
    floor_once(conn)
    k += 1
  end
  (now - t) / (ROUNDS * ROWS) * 1e9
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
  Kiln::DB::Scope.use(conn)
  per_import = import_us(conn)
  per_pluck = pluck_us
  per_floor = floor_ns(conn)
  print "#{t[0]} import_us_per_row #{per_import.round(2)} pluck_ns_per_row #{per_pluck.round} "
  print "floor_ns_per_row #{per_floor.round}\n"
  conn.exec('DROP TABLE kiln_probe_item', [])
  Kiln::DB::Scope.use(nil)
  conn.close
  i += 1
end
print "ok import_pluck\n"
