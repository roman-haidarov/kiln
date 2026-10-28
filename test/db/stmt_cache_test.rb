require 'kiln/db'
require 'test/db/support'

Thread.current

Target = Struct.new(:db, :host, :port, :user, :password, :database, :ca_path, :tls_name)

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

def open_at(target, cache)
  Kiln::DB::Conn.open(Kiln::DB::Native::KIND_MY, target.host, target.port, target.user, target.password,
                      target.database, target.ca_path, target.tls_name, statement_cache: cache)
end

def status_number(conn, name)
  rows = conn.exec("SHOW GLOBAL STATUS LIKE '#{name}'", [])
  need(name, rows.length == 1)
  rows[0][1].to_s.to_i
end

def bad_cache_raises?(target, value)
  Kiln::DB::Conn.open(Kiln::DB::Native::KIND_MY, target.host, target.port, target.user, target.password,
                      target.database, target.ca_path, target.tls_name, statement_cache: value, timeout: 1)
  false
rescue Kiln::DB::ConfigError
  true
end

def check_bad(target)
  values = [-1, 257, '32', nil]
  i = 0
  while i < values.length
    need('bad cache', bad_cache_raises?(target, values[i]))
    i += 1
  end
  line('cache', 'bad_cache', 'ConfigError')
end

def repeat_select(conn, sql, value, count)
  i = 0
  while i < count
    rows = conn.exec(sql, [])
    need("repeat #{sql}", rows.length == 1 && rows[0][0].to_s == value)
    i += 1
  end
end

def check_prepare_delta(target, observer)
  conn = open_at(target, 32)
  before = status_number(observer, 'Com_stmt_prepare')
  repeat_select(conn, 'SELECT 7 AS kiln_sc_delta', '7', 2000)
  growth = status_number(observer, 'Com_stmt_prepare') - before - 1
  conn.close
  line(target.db, 'prepare_delta<=2', growth <= 2 ? 'yes' : 'no')
  need("#{target.db} prepare delta #{growth}", growth <= 2)
end

def values_list(count)
  parts = []
  n = 1
  while n <= count
    parts << "(#{n})"
    n += 1
  end
  parts.join(',')
end

def fill_ids(conn, table, count)
  conn.exec("DROP TABLE IF EXISTS #{table}", [])
  conn.exec("CREATE TABLE #{table} (id INT PRIMARY KEY) ENGINE=InnoDB", [])
  conn.exec("INSERT INTO #{table} (id) VALUES #{values_list(count)}", [])
end

def take_some(conn, sql, limit)
  taken = 0
  conn.each_row(sql, []) do |row|
    need('streamed cell', row.length == 1 && row[0].to_s == (taken + 1).to_s)
    taken += 1
    break if taken == limit
  end
  taken
end

def distinct_selects?(conn, count)
  i = 0
  while i < count
    rows = conn.exec("SELECT #{i} AS kiln_sc_n", [])
    return false unless rows.length == 1 && rows[0][0].to_s == i.to_s

    i += 1
  end
  true
end

def ids_in_order?(rows, count)
  return false unless rows.length == count

  id = 1
  while id <= count
    return false unless rows[id - 1][0].to_s == id.to_s

    id += 1
  end
  true
end

def check_open_result(target)
  conn = open_at(target, 32)
  fill_ids(conn, 'kiln_sc_stream', 6)
  taken = take_some(conn, 'SELECT id FROM kiln_sc_stream ORDER BY id', 3)
  usable = distinct_selects?(conn, 40)
  again = ids_in_order?(conn.exec('SELECT id FROM kiln_sc_stream ORDER BY id', []), 6)
  conn.exec('DROP TABLE kiln_sc_stream', [])
  conn.close
  ok = taken == 3 && usable && again
  line(target.db, 'open_result', ok ? 'yes' : 'no')
  need("#{target.db} open result", ok)
end

def drop_and_close(conn, table)
  conn.exec("DROP TABLE #{table}", [])
  broken = conn.broken?
  conn.close
  broken
end

def check_large_break(target)
  conn = open_at(target, 8)
  fill_ids(conn, 'kiln_sc_big', 3000)
  taken = take_some(conn, 'SELECT id FROM kiln_sc_big ORDER BY id', 300)
  usable = distinct_selects?(conn, 40)
  whole = take_some(conn, 'SELECT id FROM kiln_sc_big ORDER BY id', 3000)
  broken = drop_and_close(conn, 'kiln_sc_big')
  ok = taken == 300 && usable && whole == 3000 && !broken
  line(target.db, 'large_break', ok ? 'yes' : 'no')
  need("#{target.db} large break #{taken} #{usable} #{whole} #{broken}", ok)
end

def bound_held(target, observer)
  before = status_number(observer, 'Prepared_stmt_count')
  conn = open_at(target, 32)
  need("#{target.db} bound rows", distinct_selects?(conn, 100))
  held = status_number(observer, 'Prepared_stmt_count') - before
  conn.close
  [held, status_number(observer, 'Prepared_stmt_count') - before]
end

def check_bound(target, observer)
  held, left = bound_held(target, observer)
  ok = held >= 0 && held <= 32 && left.zero?
  line(target.db, 'bound', ok ? 'yes' : 'no')
  need("#{target.db} bound #{held} #{left}", ok)
end

def alter_row?(rows, width)
  return false unless rows.length == 1 && rows[0].length == width
  return false unless rows[0][0].to_s == '1' && rows[0][1].to_s == 'a'

  width == 2 || rows[0][2].to_s == '7'
end

def alter_setup(conn)
  conn.exec('DROP TABLE IF EXISTS kiln_sc_alter', [])
  conn.exec('CREATE TABLE kiln_sc_alter (id INT PRIMARY KEY, name VARCHAR(20) NOT NULL) ENGINE=InnoDB', [])
  conn.exec("INSERT INTO kiln_sc_alter (id, name) VALUES (1, 'a')", [])
end

def check_alter(target)
  conn = open_at(target, 32)
  alter_setup(conn)
  need("#{target.db} alter before", alter_row?(conn.exec('SELECT * FROM kiln_sc_alter WHERE id = 1', []), 2))
  conn.exec('ALTER TABLE kiln_sc_alter ADD COLUMN extra INT NOT NULL DEFAULT 7', [])
  ok = alter_row?(conn.exec('SELECT * FROM kiln_sc_alter WHERE id = 1', []), 3)
  drop_and_close(conn, 'kiln_sc_alter')
  line(target.db, 'alter', ok ? 'yes' : 'no')
  need("#{target.db} alter", ok)
end

def check_disabled(target, observer)
  conn = open_at(target, 0)
  before = status_number(observer, 'Com_stmt_prepare')
  repeat_select(conn, 'SELECT 3 AS kiln_sc_off', '3', 20)
  growth = status_number(observer, 'Com_stmt_prepare') - before - 1
  conn.close
  line(target.db, 'disabled', growth >= 20 ? 'yes' : 'no')
  need("#{target.db} disabled #{growth}", growth >= 20)
end

def bind_row?(rows, base, shift, tag)
  rows.length == 1 && rows[0][0].to_s.to_i == base + shift && rows[0][1].to_s == tag
end

def check_binds_eviction(target)
  conn = open_at(target, 8)
  k = 0
  while k < 800
    shift = k % 40
    rows = conn.exec("SELECT ? + #{shift} AS a, ? AS b", [k * 7, "s#{k}"])
    need("#{target.db} binds #{k}", bind_row?(rows, k * 7, shift, "s#{k}"))
    k += 1
  end
  conn.close
  line(target.db, 'binds_eviction', 'yes')
end

def failed_class(conn)
  conn.exec('SELEC 1 FROM kiln_sc_nowhere', [])
  'none'
rescue Kiln::DB::Error => e
  e.class.to_s
end

def failed_classes(conn, observer)
  before = status_number(observer, 'Prepared_stmt_count')
  classes = [failed_class(conn), failed_class(conn), failed_class(conn)]
  [classes, status_number(observer, 'Prepared_stmt_count') - before]
end

def check_failed_prepare(target, observer)
  conn = open_at(target, 32)
  repeat_select(conn, 'SELECT 1 AS kiln_sc_warm', '1', 1)
  classes, delta = failed_classes(conn, observer)
  repeat_select(conn, 'SELECT 1 AS kiln_sc_warm', '1', 1)
  conn.close
  ok = classes.uniq.length == 1 && classes[0] != 'none' && delta.zero?
  line(target.db, 'failed_prepare', ok ? 'yes' : 'no')
  need("#{target.db} failed prepare #{classes.join(',')} #{delta}", ok)
end

def run_engine(target)
  observer = open_at(target, 0)
  check_prepare_delta(target, observer)
  check_open_result(target)
  check_alter(target)
  check_disabled(target, observer)
  check_bound(target, observer)
  check_large_break(target)
  check_binds_eviction(target)
  check_failed_prepare(target, observer)
  observer.close
end

def target_for(text, db, key)
  Target.new(db, env_line(text, "#{key}_HOST"), env_line(text, "#{key}_PORT").to_i, env_line(text, 'KILN_DB_MY_USER'),
             env_line(text, 'KILN_DB_MY_PASSWORD'), env_line(text, 'KILN_DB_MY_DB'),
             "#{env_line(text, 'KILN_DB_CONFIG_DIR')}/ca.crt", env_line(text, 'KILN_DB_TLS_NAME'))
end

text = File.read('build/db-runtime/session.env')
check_bad(target_for(text, 'mysql', 'DB_MY'))
run_engine(target_for(text, 'mysql', 'DB_MY'))
run_engine(target_for(text, 'mariadb', 'DB_MARIA'))
print "ok stmt_cache\n"
