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
  Kiln::DB::Conn.open(Kiln::DB::Native::KIND_MY, env_line(text, 'DB_MARIA_HOST'), env_line(text, 'DB_MARIA_PORT').to_i,
                      user, pass, env_line(text, 'KILN_DB_MY_DB'), '', '', tls: :disable)
end

def guard_account(conn)
  host = conn.query("SELECT SUBSTRING_INDEX(USER(), '@', -1)", [])[0][0]
  need('client host as the server sees it', host.is_a?(String) && host.match?(/\A[0-9A-Za-z.:_-]+\z/))
  "'kiln_guard_user'@'#{host}'"
end

text = File.read('build/db-runtime/session.env')
conn = open_pg(text)
other = open_pg(text)
Kiln::DB::Scope.use(conn)
begin
  conn.query('DROP TABLE IF EXISTS kiln_guard_ddl', [])
  conn.query('CREATE TABLE kiln_guard_ddl(id INT PRIMARY KEY, name TEXT)', [])
  other.query("SET lock_timeout = '100ms'", [])
  blocked = false
  Kiln::DB.transaction do
    need('copy eligible', Kiln::DB::Schema.copy_table?(conn, 'kiln_guard_ddl'))
    begin
      other.query('ALTER TABLE kiln_guard_ddl ENABLE ROW LEVEL SECURITY', [])
    rescue Kiln::DB::Error => e
      blocked = e.sqlstate == '55P03'
    end
  end
  need('schema stable during import', blocked)
  other.query('ALTER TABLE kiln_guard_ddl ENABLE ROW LEVEL SECURITY', [])
  puts 'ok schema lock lifetime'

  conn.query('DROP TABLE IF EXISTS kiln_guard_part CASCADE', [])
  conn.query('CREATE TABLE kiln_guard_part(id INT, name TEXT) PARTITION BY RANGE(id)', [])
  conn.query('CREATE TABLE kiln_guard_child PARTITION OF kiln_guard_part FOR VALUES FROM (0) TO (100)', [])
  conn.query('CREATE OR REPLACE FUNCTION kiln_guard_skip() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NULL; END $$', [])
  conn.query('CREATE TRIGGER skip_row BEFORE INSERT ON kiln_guard_child FOR EACH ROW EXECUTE FUNCTION kiln_guard_skip()', [])
  GuardItem.define_table(:postgres, 'kiln_guard_part', %w[id name], ['id'], 'g')
  skipped = false
  begin
    GuardItem.import([{'id' => 1, 'name' => 'skipped'}])
  rescue Kiln::DB::InvariantViolation
    skipped = true
  end
  need('partition skip detected', skipped && conn.query('SELECT COUNT(*) FROM kiln_guard_part', [])[0][0] == 0)
  Kiln::DB.transaction do
    need('partition COPY eligible', Kiln::DB::Schema.copy_table?(conn, 'kiln_guard_part'))
    other.query('BEGIN', [])
    concurrent = Kiln::DB::Schema.copy_table?(other, 'kiln_guard_part')
    other.query('ROLLBACK', [])
    need('partition imports run concurrently', concurrent)
  end
  puts 'ok partition guard'

  conn.query('DROP TRIGGER skip_row ON kiln_guard_child', [])
  conn.query('DROP ROLE IF EXISTS kiln_guard_insert', [])
  conn.query('CREATE ROLE kiln_guard_insert', [])
  conn.query('GRANT INSERT, SELECT ON kiln_guard_part TO kiln_guard_insert', [])
  conn.query('SET ROLE kiln_guard_insert', [])
  Kiln::DB.transaction do
    need('partition COPY with INSERT only', Kiln::DB::Schema.copy_table?(conn, 'kiln_guard_part'))
    GuardItem.import([{'id' => 1, 'name' => 'insert'}])
  end
  conn.query('RESET ROLE', [])
  puts 'ok partition INSERT privilege'

  conn.query('DROP TABLE IF EXISTS kiln_guard_snapshot', [])
  conn.query('CREATE TABLE kiln_guard_snapshot(id INT PRIMARY KEY, name TEXT)', [])
  GuardItem.define_table(:postgres, 'kiln_guard_snapshot', %w[id name], ['id'], 'g')
  Kiln::DB.transaction do
    conn.query('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ', [])
    need('snapshot before trigger', Kiln::DB::Schema.key_triggers(conn, 'kiln_guard_snapshot', false) == 0)
    other.query('CREATE TRIGGER skip_row BEFORE INSERT ON kiln_guard_snapshot FOR EACH ROW EXECUTE FUNCTION kiln_guard_skip()', [])
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
  conn.query('RESET ROLE', [])
  conn.query('DROP TABLE IF EXISTS kiln_guard_ddl', [])
  conn.query('DROP TABLE IF EXISTS kiln_guard_part CASCADE', [])
  conn.query('DROP TABLE IF EXISTS kiln_guard_snapshot', [])
  conn.query('DROP FUNCTION IF EXISTS kiln_guard_skip()', [])
  conn.query('DROP ROLE IF EXISTS kiln_guard_insert', [])
  Kiln::DB::Scope.use(nil)
  other.close
  conn.close
end

conn = open_maria(text, 'root', env_line(text, 'KILN_DB_MY_ROOT_PASSWORD') || '')
guard_user = guard_account(conn)
limited = nil
begin
  conn.query('DROP TABLE IF EXISTS kiln_guard_hidden', [])
  conn.query('CREATE TABLE kiln_guard_hidden(id INT PRIMARY KEY, name VARCHAR(20))', [])
  conn.query('CREATE TRIGGER kiln_guard_hidden_t BEFORE INSERT ON kiln_guard_hidden FOR EACH ROW SET NEW.id = 3 - NEW.id', [])
  conn.query("DROP USER IF EXISTS #{guard_user}", [])
  conn.query("CREATE USER #{guard_user} IDENTIFIED BY 'guard-test'", [])
  database = Kiln::DB::Sql.quote(:mysql, env_line(text, 'KILN_DB_MY_DB'))
  conn.query("GRANT SELECT, INSERT, UPDATE, DELETE ON #{database}.kiln_guard_hidden TO #{guard_user}", [])
  limited = open_maria(text, 'kiln_guard_user', 'guard-test')
  rows = limited.query(
    "SELECT action_statement FROM information_schema.triggers WHERE event_object_table = 'kiln_guard_hidden'", []
  )
  need('trigger body hidden', rows.all? { |row| row[0].nil? })
  Kiln::DB::Scope.use(limited)
  GuardItem.define_table(:mysql, 'kiln_guard_hidden', %w[id name], ['id'], 'g')
  rejected = false
  begin
    GuardItem.import([{'id' => 1, 'name' => 'Alice'}, {'id' => 2, 'name' => 'Bob'}], {returning: true})
  rescue Kiln::DB::UnsupportedReturn
    rejected = true
  end
  need('hidden trigger rejected', rejected)
  need('no writes', conn.query('SELECT COUNT(*) FROM kiln_guard_hidden', [])[0][0] == 0)
  puts 'ok hidden trigger guard'

  Kiln::DB::Scope.use(conn)
  conn.query('DROP TABLE kiln_guard_hidden', [])
  conn.query('CREATE TABLE kiln_guard_hidden(id VARCHAR(10) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci PRIMARY KEY, name VARCHAR(20))', [])
  result = GuardItem.import([{'id' => 'a', 'name' => 'first'}, {'id' => 'b', 'name' => 'middle'},
                            {'id' => 'a ', 'name' => 'last'}], {returning: true, on_duplicate_key_update: true})
  need('canonical upsert order', result.returned.length == 2 && result.returned[0][1] == 'middle' && result.returned[1][1] == 'last')
  puts 'ok canonical upsert mapping'

  conn.query('DROP TABLE IF EXISTS kiln_guard_conflict', [])
  conn.query('CREATE TABLE kiln_guard_conflict(id INT PRIMARY KEY, name VARCHAR(20), v INT)', [])
  conn.query('CREATE DATABASE IF NOT EXISTS kiln_guard_other', [])
  conn.query('USE kiln_guard_other', [])
  conn.query('DROP TABLE IF EXISTS kiln_guard_conflict', [])
  conn.query('CREATE TABLE kiln_guard_conflict(id INT PRIMARY KEY, name VARCHAR(20) UNIQUE, v INT)', [])
  conn.query("INSERT INTO kiln_guard_conflict VALUES(2,'seed',7)", [])
  GuardItem.define_table(:mysql, 'kiln_guard_conflict', %w[id name v], ['id'], 'g')
  rejected = false
  begin
    GuardItem.import([{'id' => 1, 'name' => 'seed', 'v' => 99}], {on_duplicate_key_update: true, returning: true})
  rescue Kiln::DB::AmbiguousConflict
    rejected = true
  end
  need('current database conflict guard', rejected)
  need('conflicting row unchanged', conn.query('SELECT v FROM kiln_guard_conflict', [])[0][0] == 7)
  puts 'ok current database conflict guard'
ensure
  Kiln::DB::Scope.use(nil)
  limited&.close
  conn.query("USE #{Kiln::DB::Sql.quote(:mysql, env_line(text, 'KILN_DB_MY_DB'))}", [])
  conn.query('DROP DATABASE IF EXISTS kiln_guard_other', [])
  conn.query('DROP TABLE IF EXISTS kiln_guard_conflict', [])
  conn.query('DROP TABLE IF EXISTS kiln_guard_hidden', [])
  conn.query("DROP USER IF EXISTS #{guard_user}", [])
  conn.close
end
