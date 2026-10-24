require 'kiln/db'
require 'test/db/support'

Thread.current

class RvPlain < Kiln::DB::Model
end

class RvRls < Kiln::DB::Model
end

class RvRule < Kiln::DB::Model
end

class RvBin < Kiln::DB::Model
end

class RvFlip < Kiln::DB::Model
end

class RvNum < Kiln::DB::Model
end

class RvNoisy < Kiln::DB::Model
end

class RvMyFlip < Kiln::DB::Model
end

PG_TABLES = %w[kiln_rv_plain kiln_rv_how kiln_rv_rls kiln_rv_rule kiln_rv_log kiln_rv_bin kiln_rv_flip kiln_rv_num
               kiln_rv_noisy].freeze
NOISY_ROWS = 20_000

def need(label, cond)
  return if cond

  print "FAILED #{label}\n"
  raise label
end

def open_pg(text, timeout = 60)
  ca = "#{env_line(text, 'KILN_DB_CONFIG_DIR')}/ca.crt"
  Kiln::DB::Conn.open(Kiln::DB::Native::KIND_PG, env_line(text, 'DB_PG17_HOST'), env_line(text, 'DB_PG17_PORT').to_i,
                      env_line(text, 'KILN_DB_PG_USER'), env_line(text, 'KILN_DB_PG_PASSWORD'),
                      env_line(text, 'KILN_DB_PG_DB'), ca, env_line(text, 'KILN_DB_TLS_NAME'), timeout: timeout)
end

def open_maria(text)
  ca = "#{env_line(text, 'KILN_DB_CONFIG_DIR')}/ca.crt"
  Kiln::DB::Conn.open(Kiln::DB::Native::KIND_MY, env_line(text, 'DB_MARIA_HOST'), env_line(text, 'DB_MARIA_PORT').to_i,
                      env_line(text, 'KILN_DB_MY_USER'), env_line(text, 'KILN_DB_MY_PASSWORD'),
                      env_line(text, 'KILN_DB_MY_DB'), ca, env_line(text, 'KILN_DB_TLS_NAME'))
end

def count_of(conn, sql)
  conn.exec(sql, [])[0][0].to_s.to_i
end

def two_rows
  [{ 'id' => 1, 'name' => 'Alice' }, { 'id' => 2, 'name' => 'Bob' }]
end

def error_name
  yield
  'none'
rescue ArgumentError
  'ArgumentError'
rescue Kiln::DB::Error => e
  e.class.to_s.split('::').last
end

def check_copy_kept(conn)
  RvPlain.import(two_rows)
  how = conn.exec('SELECT DISTINCT how FROM kiln_rv_how', [])
  print "plain path #{how.length == 1 ? how[0][0] : how.length}\n"
  need('plain copy', how.length == 1 && how[0][0] == 'COPY')
end

def check_rls(conn)
  result = RvRls.import(two_rows)
  rows = count_of(conn, 'SELECT COUNT(*) FROM kiln_rv_rls')
  print "rls import #{result.state} rows=#{rows}\n"
  need('rls', rows == 2)
end

def check_rule(conn)
  RvRule.import(two_rows)
  rows = count_of(conn, 'SELECT COUNT(*) FROM kiln_rv_rule')
  logged = count_of(conn, 'SELECT COUNT(*) FROM kiln_rv_log')
  print "rule import rows=#{rows} log=#{logged}\n"
  need('rule', rows == 2 && logged == 2)
end

def bytea_back(conn, value)
  conn.exec('SELECT $1::bytea', [value])[0][0]
end

def check_nul(conn)
  cases = ["a\0b".b, "\0".b, "a\xFFb".b, '\\x41'.b, 'a\\\\b'.b]
  i = 0
  while i < cases.length
    got = bytea_back(conn, cases[i])
    print "nul case #{i} same=#{got.b == cases[i]} size=#{got.bytesize}\n"
    need("nul #{i}", got.b == cases[i])
    i += 1
  end
  text = error_name { conn.exec('SELECT $1::text', ["before\0after"]) }
  print "nul text #{text}\n"
  need('nul text', text == 'ArgumentError')
  typed = conn.exec('SELECT $1::int + 1, $2::jsonb', ['41'.b, '{"a":1}'.b])[0]
  print "ascii binary as text #{typed[0]} #{typed[1]}\n"
  need('ascii binary as text', typed[0] == 42)
  RvBin.import([{ 'id' => 1, 'b' => "x\0y".b }])
  stored = conn.exec('SELECT b FROM kiln_rv_bin WHERE id = 1', [])[0][0]
  print "nul import same=#{stored.b == "x\0y".b}\n"
  need('nul import', stored.b == "x\0y".b)
end

def prepared_count(conn)
  count_of(conn, "SELECT COUNT(*) FROM pg_prepared_statements WHERE statement NOT LIKE '%pg_prepared%'")
end

def run_twice(conn)
  conn.exec('SELECT 1 AS kiln_rv_one', [])
  conn.exec('SELECT 1 AS kiln_rv_one', [])
end

def check_discard(text)
  conn = open_pg(text)
  k = 0
  while k < 40
    run_twice(conn)
    conn.exec('DISCARD PLANS', [])
    k += 1
  end
  after_plans = prepared_count(conn)
  conn.exec('DEALLOCATE ALL', [])
  after_all = prepared_count(conn)
  run_twice(conn)
  again = prepared_count(conn)
  name = conn.exec("SELECT name FROM pg_prepared_statements WHERE statement LIKE '%kiln_rv_one%'", [])[0][0]
  conn.exec("DEALLOCATE #{name}", [])
  run_twice(conn)
  after_one = prepared_count(conn)
  conn.close
  print "discard plans=#{after_plans} all=#{after_all} again=#{again} one=#{after_one}\n"
  need('discard', after_plans == 1 && after_all.zero? && again == 1 && after_one == 1)
end

def check_flip(conn)
  name = error_name { RvFlip.import(two_rows, { returning: true }) }
  rows = count_of(conn, 'SELECT COUNT(*) FROM kiln_rv_flip')
  print "flip returning #{name} rows=#{rows}\n"
  need('flip returning', name == 'UnsupportedReturn' && rows.zero?)
  RvFlip.import(two_rows)
  moved = conn.exec('SELECT id, name FROM kiln_rv_flip ORDER BY id', [])
  print "flip plain #{moved.map { |row| "#{row[0]}:#{row[1]}" }.join(',')}\n"
  need('flip plain', moved.length == 2 && moved[0][1] == 'Bob')
end

def check_scaled
  rows = [{ 'id' => '1', 'name' => 'first' }, { 'id' => '2', 'name' => 'second' }]
  result = RvNum.import(rows, { returning: true })
  status = [result.input_status(0), result.input_status(1)]
  print "scaled returning n=#{result.returned.length} status=#{status.join(',')}\n"
  need('scaled', result.returned.length == 2 && status == %w[inserted inserted])
  one = RvNum.import([{ 'id' => '3', 'name' => 'third' }], { returning: true })
  print "scaled single #{one.returned.length == 1 ? one.returned[0][1] : one.returned.length}\n"
  need('scaled single', one.returned.length == 1 && one.returned[0][1] == 'third')
end

def noisy_rows
  body = 'b' * 1000
  rows = []
  i = 0
  while i < NOISY_ROWS
    rows << { 'id' => i, 'body' => body }
    i += 1
  end
  rows
end

def check_noisy(conn)
  rows = noisy_rows
  name = error_name { RvNoisy.import(rows) }
  stored = count_of(conn, 'SELECT COUNT(*) FROM kiln_rv_noisy')
  print "copy notices #{name} rows=#{stored}\n"
  need('copy notices', name == 'none' && stored == NOISY_ROWS)
end

def check_maria(text)
  conn = open_maria(text)
  Kiln::DB::Scope.use(conn)
  conn.exec('DROP TABLE IF EXISTS kiln_rv_my_flip', [])
  conn.exec('CREATE TABLE kiln_rv_my_flip (id INT PRIMARY KEY, name VARCHAR(20))', [])
  conn.exec('CREATE TRIGGER kiln_rv_my_flip_t BEFORE INSERT ON kiln_rv_my_flip FOR EACH ROW ' \
            'SET NEW.id = 3 - NEW.id', [])
  RvMyFlip.define_table(:mysql, 'kiln_rv_my_flip', %w[id name], ['id'], 'mf')
  name = error_name { RvMyFlip.import(two_rows, { returning: true }) }
  rows = count_of(conn, 'SELECT COUNT(*) FROM kiln_rv_my_flip')
  conn.exec('DROP TABLE kiln_rv_my_flip', [])
  Kiln::DB::Scope.use(nil)
  conn.close
  print "mariadb flip returning #{name} rows=#{rows}\n"
  need('mariadb flip', name == 'UnsupportedReturn' && rows.zero?)
end

def prepare_triggers(conn)
  conn.exec('CREATE OR REPLACE FUNCTION kiln_rv_note() RETURNS trigger LANGUAGE plpgsql AS ' \
            '$$ BEGIN INSERT INTO kiln_rv_how VALUES (left(current_query(), 4)); RETURN NEW; END $$', [])
  conn.exec('CREATE OR REPLACE FUNCTION kiln_rv_flip() RETURNS trigger LANGUAGE plpgsql AS ' \
            '$$ BEGIN NEW.id := 3 - NEW.id; RETURN NEW; END $$', [])
  conn.exec('CREATE OR REPLACE FUNCTION kiln_rv_shout() RETURNS trigger LANGUAGE plpgsql AS ' \
            "$$ BEGIN RAISE NOTICE '%', repeat('n', 4000); RETURN NEW; END $$", [])
end

def row_trigger(conn, table, timing, function)
  conn.exec("CREATE TRIGGER #{table}_t #{timing} INSERT ON #{table} FOR EACH ROW EXECUTE FUNCTION #{function}()", [])
end

def prepare_rls(conn)
  conn.exec('CREATE TABLE kiln_rv_rls (id INT PRIMARY KEY, name TEXT)', [])
  conn.exec('ALTER TABLE kiln_rv_rls ENABLE ROW LEVEL SECURITY', [])
  conn.exec('ALTER TABLE kiln_rv_rls FORCE ROW LEVEL SECURITY', [])
  conn.exec('CREATE POLICY kiln_rv_rls_all ON kiln_rv_rls USING (true) WITH CHECK (true)', [])
end

def prepare_rule(conn)
  conn.exec('CREATE TABLE kiln_rv_rule (id INT PRIMARY KEY, name TEXT)', [])
  conn.exec('CREATE TABLE kiln_rv_log (id INT)', [])
  conn.exec('CREATE RULE kiln_rv_rule_log AS ON INSERT TO kiln_rv_rule ' \
            'DO ALSO INSERT INTO kiln_rv_log VALUES (NEW.id)', [])
end

def prepare_tables(conn)
  conn.exec('CREATE TABLE kiln_rv_how (how TEXT)', [])
  conn.exec('CREATE TABLE kiln_rv_plain (id INT PRIMARY KEY, name TEXT)', [])
  row_trigger(conn, 'kiln_rv_plain', 'AFTER', 'kiln_rv_note')
  prepare_rls(conn)
  prepare_rule(conn)
  conn.exec('CREATE TABLE kiln_rv_bin (id INT PRIMARY KEY, b BYTEA)', [])
  conn.exec('CREATE TABLE kiln_rv_flip (id INT PRIMARY KEY, name TEXT)', [])
  row_trigger(conn, 'kiln_rv_flip', 'BEFORE', 'kiln_rv_flip')
  conn.exec('CREATE TABLE kiln_rv_num (id NUMERIC(10, 2) PRIMARY KEY, name TEXT)', [])
  conn.exec('CREATE TABLE kiln_rv_noisy (id INT PRIMARY KEY, body TEXT)', [])
  row_trigger(conn, 'kiln_rv_noisy', 'BEFORE', 'kiln_rv_shout')
end

def define_models
  RvPlain.define_table(:postgres, 'kiln_rv_plain', %w[id name], ['id'], 'rp')
  RvRls.define_table(:postgres, 'kiln_rv_rls', %w[id name], ['id'], 'rr')
  RvRule.define_table(:postgres, 'kiln_rv_rule', %w[id name], ['id'], 'ru')
  RvBin.define_table(:postgres, 'kiln_rv_bin', %w[id b], ['id'], 'rb')
  RvFlip.define_table(:postgres, 'kiln_rv_flip', %w[id name], ['id'], 'rf')
  RvNum.define_table(:postgres, 'kiln_rv_num', %w[id name], ['id'], 'rm')
  RvNoisy.define_table(:postgres, 'kiln_rv_noisy', %w[id body], ['id'], 'rn')
end

def prepare(conn)
  PG_TABLES.each { |table| conn.exec("DROP TABLE IF EXISTS #{table}", []) }
  prepare_triggers(conn)
  prepare_tables(conn)
  define_models
end

def finish(conn)
  PG_TABLES.each { |table| conn.exec("DROP TABLE IF EXISTS #{table}", []) }
  %w[kiln_rv_note kiln_rv_flip kiln_rv_shout].each { |name| conn.exec("DROP FUNCTION IF EXISTS #{name}()", []) }
  Kiln::DB::Scope.use(nil)
  conn.close
end

text = File.read('build/db-runtime/session.env')
conn = open_pg(text)
Kiln::DB::Scope.use(conn)
prepare(conn)
check_copy_kept(conn)
check_rls(conn)
check_rule(conn)
check_nul(conn)
check_flip(conn)
check_scaled
check_noisy(conn)
finish(conn)
check_discard(text)
check_maria(text)
print "ok review_fixes\n"
