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

class ExactUser < Kiln::DB::Model
end

class ExactMail < Kiln::DB::Model
end

def exec_ddl(conn, sql)
  conn.exec(sql, [])
end

def run_db(db, kind, host, port, user, password, database, ca_path, tls_name)
  conn = Kiln::DB::Conn.open(kind, host, port, user, password, database, ca_path, tls_name)
  Kiln::DB::Scope.use(conn)
  dialect = conn.dialect
  engine = dialect == :mysql ? ' ENGINE=InnoDB' : ''
  exec_ddl(conn, 'DROP TABLE IF EXISTS kiln_exact_mail')
  exec_ddl(conn, 'DROP TABLE IF EXISTS kiln_exact_user')
  exec_ddl(conn, "CREATE TABLE kiln_exact_user (id INT NOT NULL, name VARCHAR(40) NOT NULL, PRIMARY KEY (id))#{engine}")
  mail = "CREATE TABLE kiln_exact_mail (id INT NOT NULL, name VARCHAR(40) NOT NULL, PRIMARY KEY (id), UNIQUE (name))#{engine}"
  exec_ddl(conn, mail)
  ExactUser.define_table(dialect, 'kiln_exact_user', %w[id name], ['id'], 'u')
  ExactMail.define_table(dialect, 'kiln_exact_mail', %w[id name], ['id'], 'm')
  ExactUser.import([{ 'id' => 1, 'name' => 'ada' }])
  exact = 'open'
  begin
    ExactUser.import([{ 'id' => 1, 'name' => 'ADA' }],
                     { on_duplicate_key_update: true, require_exact_status: true })
    exact = 'passed'
  rescue Kiln::DB::UnsupportedExactStatus
    exact = 'blocked'
  end
  after_exact = ExactUser.all.count
  loose = ExactUser.import([{ 'id' => 1, 'name' => 'ADA' }],
                           { on_duplicate_key_update: true, require_exact_status: false })
  stored = ExactUser.all.where(ExactUser.col('id').eq(1)).pluck(ExactUser.col('name'))
  ambiguous = 'pg'
  if dialect == :mysql
    begin
      ExactMail.import([{ 'id' => 1, 'name' => 'ada' }], { on_duplicate_key_update: true })
      ambiguous = 'passed'
    rescue Kiln::DB::AmbiguousConflict
      ambiguous = 'blocked'
    end
  end
  mail_n = ExactMail.all.count
  exec_ddl(conn, 'DROP TABLE IF EXISTS kiln_exact_mail')
  exec_ddl(conn, 'DROP TABLE IF EXISTS kiln_exact_user')
  line(db, 'exact', "#{exact} #{after_exact}")
  line(db, 'loose', "#{loose.input_status(0)} #{stored[0]}")
  line(db, 'mail', "#{ambiguous} #{mail_n}")
  conn.close
end

path = 'build/db-runtime/session.env'
unless File.exist?(path)
  print "blocked exact\n"
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
run_db('pg17', Kiln::DB::Native::KIND_PG, env_line(text, 'DB_PG17_HOST'), env_line(text, 'DB_PG17_PORT').to_i, pg_user,
       pg_password, pg_db, ca_path, tls_name)
run_db('pg18', Kiln::DB::Native::KIND_PG, env_line(text, 'DB_PG18_HOST'), env_line(text, 'DB_PG18_PORT').to_i, pg_user,
       pg_password, pg_db, ca_path, tls_name)
run_db('mysql84', Kiln::DB::Native::KIND_MY, env_line(text, 'DB_MY_HOST'), env_line(text, 'DB_MY_PORT').to_i, my_user,
       my_password, my_db, ca_path, tls_name)
run_db('mariadb114', Kiln::DB::Native::KIND_MY, env_line(text, 'DB_MARIA_HOST'), env_line(text, 'DB_MARIA_PORT').to_i,
       my_user, my_password, my_db, ca_path, tls_name)
print "ok exact\n"
