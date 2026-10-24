require 'kiln/db'
require 'test/db/support'

Thread.current

class AuditItem < Kiln::DB::Model
end

def need(label, passed)
  raise label unless passed
end

def use_table(name)
  AuditItem.define_table(:postgres, name, %w[id name], ['id'], 'a')
end

text = File.read('build/db-runtime/session.env')
conn = Kiln::DB::Conn.open(Kiln::DB::Native::KIND_PG, env_line(text, 'DB_PG17_HOST'),
                          env_line(text, 'DB_PG17_PORT').to_i, env_line(text, 'KILN_DB_PG_USER'),
                          env_line(text, 'KILN_DB_PG_PASSWORD'), env_line(text, 'KILN_DB_PG_DB'),
                          "#{env_line(text, 'KILN_DB_CONFIG_DIR')}/ca.crt", env_line(text, 'KILN_DB_TLS_NAME'), timeout: 30)
Kiln::DB::Scope.use(conn)
tables = %w[kiln_audit_fk kiln_audit_rls kiln_audit_rule kiln_audit_log kiln_audit_swap kiln_audit_noise kiln_audit_identity kiln_audit_char]
tables.each { |table| conn.exec("DROP TABLE IF EXISTS #{table} CASCADE", []) }
conn.exec('DROP ROLE IF EXISTS kiln_audit_role', [])
conn.exec('CREATE ROLE kiln_audit_role', [])
begin
  conn.exec('CREATE TABLE kiln_audit_rls(id INT PRIMARY KEY, name TEXT)', [])
  conn.exec('ALTER TABLE kiln_audit_rls ENABLE ROW LEVEL SECURITY', [])
  conn.exec('CREATE POLICY allow_rows ON kiln_audit_rls FOR ALL TO kiln_audit_role USING (true) WITH CHECK (true)', [])
  conn.exec('GRANT ALL ON kiln_audit_rls TO kiln_audit_role', [])
  conn.exec('SET ROLE kiln_audit_role', [])
  use_table('kiln_audit_rls')
  need('RLS import', AuditItem.import([{'id' => 1, 'name' => 'rls'}]).state == 'COMMITTED')
  conn.exec('RESET ROLE', [])
  puts 'ok import RLS'

  conn.exec('CREATE TABLE kiln_audit_fk(id INT PRIMARY KEY REFERENCES kiln_audit_rls(id), name TEXT)', [])
  use_table('kiln_audit_fk')
  result = AuditItem.import([{'id' => 1, 'name' => 'fk'}], {returning: true})
  need('foreign key returning', result.returned == [[1, 'fk']])
  puts 'ok returning foreign keys'

  conn.exec('CREATE TABLE kiln_audit_rule(id INT PRIMARY KEY, name TEXT)', [])
  conn.exec('CREATE TABLE kiln_audit_log(id INT, name TEXT)', [])
  conn.exec('CREATE RULE audit_insert AS ON INSERT TO kiln_audit_rule DO ALSO INSERT INTO kiln_audit_log VALUES(NEW.id,NEW.name)', [])
  use_table('kiln_audit_rule')
  AuditItem.import([{'id' => 1, 'name' => 'rule'}])
  need('rule fired', conn.exec('SELECT COUNT(*) FROM kiln_audit_log', [])[0][0] == 1)
  puts 'ok import rules'

  ["a\0b".b, "\0".b, "a\\b".b, 'ascii'.b, "a\xFFb".b].each do |value|
    3.times { need('binary bind', conn.exec('SELECT $1::bytea', [value])[0][0] == value) }
  end
  rejected = false
  begin
    conn.exec('SELECT $1::text', ["before\0after"])
  rescue ArgumentError
    rejected = true
  end
  need('NUL text rejected', rejected)
  need('connection reusable', conn.exec('SELECT 42', [])[0][0] == 42)
  puts 'ok bind integrity'

  40.times do
    2.times { conn.exec('SELECT 1234567::int', []) }
    conn.exec('DISCARD PLANS', [])
  end
  need('bounded statements', conn.exec("SELECT COUNT(*) FROM pg_prepared_statements WHERE statement='SELECT 1234567::int'", [])[0][0] == 1)
  name = conn.exec("SELECT name FROM pg_prepared_statements WHERE statement='SELECT 1234567::int'", [])[0][0]
  conn.exec("DEALLOCATE #{name}", [])
  need('partial deallocate', conn.exec('SELECT 1234567::int', [])[0][0] == 1234567)
  puts 'ok statement retirement'

  conn.exec('CREATE TABLE kiln_audit_swap(id INT PRIMARY KEY, name TEXT)', [])
  conn.exec('CREATE OR REPLACE FUNCTION kiln_audit_swap_id() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN NEW.id := 3-NEW.id; RETURN NEW; END $$', [])
  conn.exec('CREATE TRIGGER swap_id BEFORE INSERT ON kiln_audit_swap FOR EACH ROW EXECUTE FUNCTION kiln_audit_swap_id()', [])
  use_table('kiln_audit_swap')
  rejected = false
  begin
    AuditItem.import([{'id' => 1, 'name' => 'Alice'}, {'id' => 2, 'name' => 'Bob'}], {returning: true})
  rescue Kiln::DB::UnsupportedReturn
    rejected = true
  end
  need('unsafe returning rejected', rejected)
  need('no writes', conn.exec('SELECT COUNT(*) FROM kiln_audit_swap', [])[0][0] == 0)
  puts 'ok returning identity'

  conn.exec('CREATE OR REPLACE FUNCTION kiln_audit_swap_id() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.id = 2 THEN RETURN NULL; END IF; RETURN NEW; END $$', [])
  rejected = false
  begin
    AuditItem.import([{'id' => 1, 'name' => 'insert'}, {'id' => 2, 'name' => 'skip'}])
  rescue Kiln::DB::InvariantViolation
    rejected = true
  end
  need('skipped row detected', rejected)
  need('partial insert rolled back', conn.exec('SELECT COUNT(*) FROM kiln_audit_swap', [])[0][0] == 0)
  puts 'ok skipped insert rollback'

  conn.exec('CREATE TABLE kiln_audit_identity(id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY, name TEXT)', [])
  use_table('kiln_audit_identity')
  rejected = false
  begin
    AuditItem.import([{'id' => 7, 'name' => 'explicit'}])
  rescue Kiln::DB::Error
    rejected = true
  end
  need('identity enforced', rejected && conn.exec('SELECT COUNT(*) FROM kiln_audit_identity', [])[0][0] == 0)
  AuditItem.import([{'name' => 'generated'}])
  need('identity generated', conn.exec('SELECT name FROM kiln_audit_identity', [])[0][0] == 'generated')
  puts 'ok identity COPY fallback'

  2.times { conn.exec('SELECT 7654321::int', []) }
  name = conn.exec("SELECT name FROM pg_prepared_statements WHERE statement='SELECT 7654321::int'", [])[0][0]
  Kiln::DB.transaction do
    conn.exec("/* prefix */ DEALLOCATE/* outer /* nested */ end */ PREPARE -- line\n#{name}/* tail */", [])
    need('deallocate comments', conn.exec('SELECT 7654321::int', [])[0][0] == 7654321)
  end
  puts 'ok commented DEALLOCATE'

  2.times { conn.exec('SELECT 8888::int', []) }
  name = conn.exec("SELECT name FROM pg_prepared_statements WHERE statement='SELECT 8888::int'", [])[0][0]
  Kiln::DB.transaction do
    conn.exec("\fDEALLOCATE\"#{name}\"", [])
    need('quoted deallocate', conn.exec('SELECT 8888::int', [])[0][0] == 8888)
  end
  puts 'ok quoted DEALLOCATE'

  conn.exec('CREATE TABLE kiln_audit_char(id CHAR(2) PRIMARY KEY, name TEXT)', [])
  use_table('kiln_audit_char')
  result = AuditItem.import([{'id' => 'a', 'name' => 'first'}, {'id' => 'a ', 'name' => 'second'}],
                            {returning: true, on_duplicate_key_ignore: true, require_exact_status: true})
  need('canonical first inserted', result.input_status(0) == 'inserted')
  need('canonical second skipped', result.input_status(1) == 'skipped_conflict')
  need('canonical returned first', result.returned.length == 1 && result.returned[0][1] == 'first')
  puts 'ok canonical conflict mapping'

  conn.exec('CREATE TABLE kiln_audit_noise(id INT, name TEXT)', [])
  conn.exec("CREATE OR REPLACE FUNCTION kiln_audit_notice() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE NOTICE '%', repeat('n',2048); RETURN NEW; END $$", [])
  conn.exec('CREATE TRIGGER notice BEFORE INSERT ON kiln_audit_noise FOR EACH ROW EXECUTE FUNCTION kiln_audit_notice()', [])
  payload = (+'').b
  5000.times { |i| payload << "#{i}\t#{'x' * 4096}\n" }
  conn.copy_in('COPY kiln_audit_noise(id,name) FROM STDIN', payload, 5000)
  need('duplex copy', conn.exec('SELECT COUNT(*) FROM kiln_audit_noise', [])[0][0] == 5000)
  puts 'ok duplex COPY'
ensure
  conn.exec('RESET ROLE', [])
  tables.each { |table| conn.exec("DROP TABLE IF EXISTS #{table} CASCADE", []) }
  conn.exec('DROP FUNCTION IF EXISTS kiln_audit_swap_id()', [])
  conn.exec('DROP FUNCTION IF EXISTS kiln_audit_notice()', [])
  conn.exec('DROP ROLE IF EXISTS kiln_audit_role', [])
  Kiln::DB::Scope.use(nil)
  conn.close
end
