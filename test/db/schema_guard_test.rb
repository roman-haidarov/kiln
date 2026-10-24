require 'kiln/db'
require 'test/db/support'

Thread.current

class GuardItem < Kiln::DB::Model
end

def need(label, value)
  raise label unless value
end

def open_pg(text)
  Kiln::DB::Conn.open(Kiln::DB::Native::KIND_PG, env_line(text, 'DB_PG17_HOST'),
                      env_line(text, 'DB_PG17_PORT').to_i, env_line(text, 'KILN_DB_PG_USER'),
                      env_line(text, 'KILN_DB_PG_PASSWORD'), env_line(text, 'KILN_DB_PG_DB'),
                      "#{env_line(text, 'KILN_DB_CONFIG_DIR')}/ca.crt", env_line(text, 'KILN_DB_TLS_NAME'))
end

def open_maria(text, user, pass)
  Kiln::DB::Conn.open(Kiln::DB::Native::KIND_MY, '127.0.0.1', env_line(text, 'DB_MARIA_PORT').to_i,
                      user, pass, env_line(text, 'KILN_DB_MY_DB'), '', '', tls: :disable)
end

text = File.read('build/db-runtime/session.env')
conn = open_pg(text)
other = open_pg(text)
Kiln::DB::Scope.use(conn)
begin
  conn.exec('DROP TABLE IF EXISTS kiln_guard_ddl', [])
  conn.exec('CREATE TABLE kiln_guard_ddl(id INT PRIMARY KEY, name TEXT)', [])
  other.exec("SET lock_timeout = '100ms'", [])
  blocked = false
  Kiln::DB.transaction do
    need('copy eligible', Kiln::DB::Schema.copy_table?(conn, 'kiln_guard_ddl'))
    begin
      other.exec('ALTER TABLE kiln_guard_ddl ENABLE ROW LEVEL SECURITY', [])
    rescue Kiln::DB::Error => e
      blocked = e.sqlstate == '55P03'
    end
  end
  need('schema stable during import', blocked)
  other.exec('ALTER TABLE kiln_guard_ddl ENABLE ROW LEVEL SECURITY', [])
  puts 'ok schema lock lifetime'

  conn.exec('DROP TABLE IF EXISTS kiln_guard_part CASCADE', [])
  conn.exec('CREATE TABLE kiln_guard_part(id INT, name TEXT) PARTITION BY RANGE(id)', [])
  conn.exec('CREATE TABLE kiln_guard_child PARTITION OF kiln_guard_part FOR VALUES FROM (0) TO (100)', [])
  conn.exec('CREATE OR REPLACE FUNCTION kiln_guard_skip() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NULL; END $$', [])
  conn.exec('CREATE TRIGGER skip_row BEFORE INSERT ON kiln_guard_child FOR EACH ROW EXECUTE FUNCTION kiln_guard_skip()', [])
  GuardItem.define_table(:postgres, 'kiln_guard_part', %w[id name], ['id'], 'g')
  skipped = false
  begin
    GuardItem.import([{'id' => 1, 'name' => 'skipped'}])
  rescue Kiln::DB::InvariantViolation
    skipped = true
  end
  need('partition skip detected', skipped && conn.exec('SELECT COUNT(*) FROM kiln_guard_part', [])[0][0] == 0)
  Kiln::DB.transaction do
    need('partition COPY eligible', Kiln::DB::Schema.copy_table?(conn, 'kiln_guard_part'))
    other.exec('BEGIN', [])
    concurrent = Kiln::DB::Schema.copy_table?(other, 'kiln_guard_part')
    other.exec('ROLLBACK', [])
    need('partition imports run concurrently', concurrent)
  end
  puts 'ok partition guard'

  conn.exec('DROP TRIGGER skip_row ON kiln_guard_child', [])
  conn.exec('DROP ROLE IF EXISTS kiln_guard_insert', [])
  conn.exec('CREATE ROLE kiln_guard_insert', [])
  conn.exec('GRANT INSERT, SELECT ON kiln_guard_part TO kiln_guard_insert', [])
  conn.exec('SET ROLE kiln_guard_insert', [])
  Kiln::DB.transaction do
    need('partition COPY with INSERT only', Kiln::DB::Schema.copy_table?(conn, 'kiln_guard_part'))
    GuardItem.import([{'id' => 1, 'name' => 'insert'}])
  end
  conn.exec('RESET ROLE', [])
  puts 'ok partition INSERT privilege'

  conn.exec('DROP TABLE IF EXISTS kiln_guard_snapshot', [])
  conn.exec('CREATE TABLE kiln_guard_snapshot(id INT PRIMARY KEY, name TEXT)', [])
  GuardItem.define_table(:postgres, 'kiln_guard_snapshot', %w[id name], ['id'], 'g')
  Kiln::DB.transaction do
    conn.exec('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ', [])
    need('snapshot before trigger', Kiln::DB::Schema.key_triggers(conn, 'kiln_guard_snapshot', false) == 0)
    other.exec('CREATE TRIGGER skip_row BEFORE INSERT ON kiln_guard_snapshot FOR EACH ROW EXECUTE FUNCTION kiln_guard_skip()', [])
    need('snapshot still stale', Kiln::DB::Schema.key_triggers(conn, 'kiln_guard_snapshot', false) == 0)
    need('snapshot COPY fallback', !Kiln::DB::Schema.copy_table?(conn, 'kiln_guard_snapshot'))
    rejected = false
    begin
      GuardItem.import([{'id' => 1, 'name' => 'snapshot'}], {returning: true})
    rescue Kiln::DB::UnsupportedReturn
      rejected = true
    end
    need('stale metadata rejected', rejected)
  end
  puts 'ok snapshot schema guard'
ensure
  conn.exec('RESET ROLE', [])
  conn.exec('DROP TABLE IF EXISTS kiln_guard_ddl', [])
  conn.exec('DROP TABLE IF EXISTS kiln_guard_part CASCADE', [])
  conn.exec('DROP TABLE IF EXISTS kiln_guard_snapshot', [])
  conn.exec('DROP FUNCTION IF EXISTS kiln_guard_skip()', [])
  conn.exec('DROP ROLE IF EXISTS kiln_guard_insert', [])
  Kiln::DB::Scope.use(nil)
  other.close
  conn.close
end

conn = open_maria(text, 'root', env_line(text, 'KILN_DB_MY_ROOT_PASSWORD') || '')
limited = nil
begin
  conn.exec('DROP TABLE IF EXISTS kiln_guard_hidden', [])
  conn.exec('CREATE TABLE kiln_guard_hidden(id INT PRIMARY KEY, name VARCHAR(20))', [])
  conn.exec('CREATE TRIGGER kiln_guard_hidden_t BEFORE INSERT ON kiln_guard_hidden FOR EACH ROW SET NEW.id = 3 - NEW.id', [])
  conn.exec("DROP USER IF EXISTS 'kiln_guard_user'@'127.0.0.1'", [])
  conn.exec("CREATE USER 'kiln_guard_user'@'127.0.0.1' IDENTIFIED BY 'guard-test'", [])
  database = Kiln::DB::Sql.quote(:mysql, env_line(text, 'KILN_DB_MY_DB'))
  conn.exec("GRANT SELECT, INSERT, UPDATE, DELETE ON #{database}.kiln_guard_hidden TO 'kiln_guard_user'@'127.0.0.1'", [])
  limited = open_maria(text, 'kiln_guard_user', 'guard-test')
  hidden = limited.exec("SELECT COUNT(*) FROM information_schema.triggers WHERE event_object_table = 'kiln_guard_hidden'", [])[0][0]
  need('trigger hidden', hidden == 0)
  Kiln::DB::Scope.use(limited)
  GuardItem.define_table(:mysql, 'kiln_guard_hidden', %w[id name], ['id'], 'g')
  rejected = false
  begin
    GuardItem.import([{'id' => 1, 'name' => 'Alice'}, {'id' => 2, 'name' => 'Bob'}], {returning: true})
  rescue Kiln::DB::UnsupportedReturn
    rejected = true
  end
  need('hidden trigger rejected', rejected)
  need('no writes', conn.exec('SELECT COUNT(*) FROM kiln_guard_hidden', [])[0][0] == 0)
  puts 'ok hidden trigger guard'

  Kiln::DB::Scope.use(conn)
  conn.exec('DROP TABLE kiln_guard_hidden', [])
  conn.exec('CREATE TABLE kiln_guard_hidden(id VARCHAR(10) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci PRIMARY KEY, name VARCHAR(20))', [])
  result = GuardItem.import([{'id' => 'a', 'name' => 'first'}, {'id' => 'b', 'name' => 'middle'},
                            {'id' => 'a ', 'name' => 'last'}], {returning: true, on_duplicate_key_update: true})
  need('canonical upsert order', result.returned.length == 2 && result.returned[0][1] == 'middle' && result.returned[1][1] == 'last')
  puts 'ok canonical upsert mapping'

  conn.exec('DROP TABLE IF EXISTS kiln_guard_conflict', [])
  conn.exec('CREATE TABLE kiln_guard_conflict(id INT PRIMARY KEY, name VARCHAR(20), v INT)', [])
  conn.exec('CREATE DATABASE IF NOT EXISTS kiln_guard_other', [])
  conn.exec('USE kiln_guard_other', [])
  conn.exec('DROP TABLE IF EXISTS kiln_guard_conflict', [])
  conn.exec('CREATE TABLE kiln_guard_conflict(id INT PRIMARY KEY, name VARCHAR(20) UNIQUE, v INT)', [])
  conn.exec("INSERT INTO kiln_guard_conflict VALUES(2,'seed',7)", [])
  GuardItem.define_table(:mysql, 'kiln_guard_conflict', %w[id name v], ['id'], 'g')
  rejected = false
  begin
    GuardItem.import([{'id' => 1, 'name' => 'seed', 'v' => 99}], {on_duplicate_key_update: true})
  rescue Kiln::DB::AmbiguousConflict
    rejected = true
  end
  need('current database conflict guard', rejected)
  need('conflicting row unchanged', conn.exec('SELECT v FROM kiln_guard_conflict', [])[0][0] == 7)
  puts 'ok current database conflict guard'
ensure
  Kiln::DB::Scope.use(nil)
  limited&.close
  conn.exec("USE #{Kiln::DB::Sql.quote(:mysql, env_line(text, 'KILN_DB_MY_DB'))}", [])
  conn.exec('DROP DATABASE IF EXISTS kiln_guard_other', [])
  conn.exec('DROP TABLE IF EXISTS kiln_guard_conflict', [])
  conn.exec('DROP TABLE IF EXISTS kiln_guard_hidden', [])
  conn.exec("DROP USER IF EXISTS 'kiln_guard_user'@'127.0.0.1'", [])
  conn.close
end
