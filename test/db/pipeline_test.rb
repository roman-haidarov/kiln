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

class PipeUser < Kiln::DB::Model
end

def cell(rows)
  return '' if rows.nil? || rows.empty? || rows[0][0].nil?

  rows[0][0].to_s
end

def run_pg(db, host, port, user, password, database, ca_path, tls_name, cap)
  conn = Kiln::DB::Conn.open(Kiln::DB::Native::KIND_PG, host, port, user, password, database, ca_path, tls_name)
  Kiln::DB::Scope.use(conn)
  PipeUser.define_table(:postgres, 'kiln_pipe_user', %w[id name], ['id'], 'u')
  conn.pipeline_begin
  conn.pipeline_exec('SELECT 7', [])
  conn.pipeline_sync
  conn.pipeline_exec('SELECT 8', [])
  conn.pipeline_sync
  first = cell(conn.pipeline_read)
  conn.pipeline_sync_read
  second = cell(conn.pipeline_read)
  conn.pipeline_sync_read
  blocked = 'open'
  begin
    PipeUser.import([{ 'id' => 1, 'name' => 'a' }])
    blocked = 'passed'
  rescue Kiln::DB::InvariantViolation
    blocked = 'blocked'
  end
  conn.pipeline_finish
  reused = cell(conn.exec('SELECT 1', []))
  if cap
    conn.pipeline_begin
    n = 0
    begin
      while n < 80
        conn.pipeline_exec('SELECT 1', [])
        n += 1
      end
    rescue Kiln::DB::CapacityError
      nil
    end
    i = 0
    while i < n
      conn.pipeline_read
      i += 1
    end
    conn.pipeline_sync
    conn.pipeline_sync_read
    conn.pipeline_finish
    line(db, 'cap', n.to_s)
  end
  line(db, 'q', "#{first},#{second}")
  line(db, 'import', blocked)
  line(db, 'reuse', reused)
  conn.close
end

def run_my(db, host, port, user, password, database, ca_path, tls_name)
  conn = Kiln::DB::Conn.open(Kiln::DB::Native::KIND_MY, host, port, user, password, database, ca_path, tls_name)
  begin
    conn.pipeline_begin
    line(db, 'pipeline', 'on')
  rescue Kiln::DB::Error
    line(db, 'pipeline', 'off')
  end
  conn.close
end

path = 'build/db-runtime/session.env'
unless File.exist?(path)
  print "blocked pipeline\n"
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
run_pg('pg17', env_line(text, 'DB_PG17_HOST'), env_line(text, 'DB_PG17_PORT').to_i, pg_user, pg_password, pg_db,
       ca_path, tls_name, true)
run_pg('pg18', env_line(text, 'DB_PG18_HOST'), env_line(text, 'DB_PG18_PORT').to_i, pg_user, pg_password, pg_db,
       ca_path, tls_name, false)
run_my('mysql84', env_line(text, 'DB_MY_HOST'), env_line(text, 'DB_MY_PORT').to_i, my_user, my_password, my_db, ca_path,
       tls_name)
run_my('mariadb114', env_line(text, 'DB_MARIA_HOST'), env_line(text, 'DB_MARIA_PORT').to_i, my_user, my_password, my_db,
       ca_path, tls_name)
print "ok pipeline\n"
