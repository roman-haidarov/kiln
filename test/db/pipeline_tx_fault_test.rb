require 'kiln/db'
require 'test/db/support'

Thread.current

def need(label, cond)
  return if cond

  print label
  print "\n"
  raise label
end

def line(db, label, value)
  print db
  print ' '
  print label
  print ' '
  print value
  print "\n"
end

def token(err)
  text = err.message.to_s
  return '22012' if text.include?('22012')
  return 'aborted' if text.include?('PGRES_PIPELINE_ABORTED')
  return '25P02' if text.include?('25P02')

  'error'
end

def take_one(conn)
  conn.pipeline_read
rescue Kiln::DB::Error => e
  token(e)
end

def value_of(got)
  return got if got.is_a?(String)
  return '' if got.nil? || got.empty? || got[0][0].nil?

  got[0][0].to_s
end

def run_db(db, host, port, user, password, database, ca_path, tls_name)
  conn = Kiln::DB::Conn.open(Kiln::DB::Native::KIND_PG, host, port, user, password, database, ca_path, tls_name)
  Kiln::DB::Scope.use(conn)
  conn.exec('DROP TABLE IF EXISTS kiln_pipe_tx', [])
  conn.exec('CREATE TABLE kiln_pipe_tx (id INT NOT NULL, PRIMARY KEY (id))', [])
  conn.exec('INSERT INTO kiln_pipe_tx (id) VALUES (1)', [])
  conn.transaction_open
  conn.pipeline_begin
  conn.pipeline_exec('SELECT 3', [])
  conn.pipeline_sync
  conn.pipeline_exec('SELECT 1/0', [])
  conn.pipeline_sync
  conn.pipeline_exec('INSERT INTO kiln_pipe_tx (id) VALUES (2)', [])
  conn.pipeline_sync
  g1 = value_of(take_one(conn))
  conn.pipeline_sync_read
  g2 = value_of(take_one(conn))
  conn.pipeline_sync_read
  g3 = value_of(take_one(conn))
  conn.pipeline_sync_read
  conn.pipeline_finish
  tx = 'open'
  begin
    conn.exec('SELECT 1', [])
    tx = 'open'
  rescue Kiln::DB::Error => e
    tx = token(e)
  end
  conn.transaction_fail
  left = conn.exec('SELECT COUNT(*) FROM kiln_pipe_tx', [])
  conn.exec('DROP TABLE IF EXISTS kiln_pipe_tx', [])
  line(db, 'g1', g1)
  line(db, 'g2', g2)
  line(db, 'g3', g3)
  line(db, 'tx', tx)
  line(db, 'left', value_of(left))
  conn.close
end

path = 'build/db-runtime/session.env'
unless File.exist?(path)
  print "blocked pipeline-tx\n"
  exit 0
end

text = File.read(path)
ca_path = "#{env_line(text, 'KILN_DB_CONFIG_DIR')}/ca.crt"
tls_name = env_line(text, 'KILN_DB_TLS_NAME')
pg_user = env_line(text, 'KILN_DB_PG_USER')
pg_password = env_line(text, 'KILN_DB_PG_PASSWORD')
pg_db = env_line(text, 'KILN_DB_PG_DB')
need('configured', Kiln::DB::Native.configure == Kiln::DB::Native::OK)
run_db('pg17', env_line(text, 'DB_PG17_HOST'), env_line(text, 'DB_PG17_PORT').to_i, pg_user, pg_password, pg_db,
       ca_path, tls_name)
run_db('pg18', env_line(text, 'DB_PG18_HOST'), env_line(text, 'DB_PG18_PORT').to_i, pg_user, pg_password, pg_db,
       ca_path, tls_name)
print "ok pipeline-tx\n"
