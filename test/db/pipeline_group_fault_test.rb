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

def read_sync(conn)
  conn.pipeline_sync_read
  'sync'
rescue Kiln::DB::Error => e
  token(e)
end

def value_of(got)
  return got if got.is_a?(String)
  return '' if got.nil? || got.empty? || got[0][0].nil?

  got[0][0].to_s
end

def run_groups(conn, db)
  conn.pipeline_begin
  conn.pipeline_exec('SELECT 1', [])
  conn.pipeline_sync
  conn.pipeline_exec('SELECT 1/0', [])
  conn.pipeline_sync
  conn.pipeline_exec('SELECT 2', [])
  conn.pipeline_sync
  g1 = value_of(take_one(conn))
  s1 = read_sync(conn)
  g2 = value_of(take_one(conn))
  s2 = read_sync(conn)
  g3 = value_of(take_one(conn))
  s3 = read_sync(conn)
  conn.pipeline_finish
  published = 0
  line(db, 'g1', g1)
  line(db, 'g2', g2)
  line(db, 'g3', g3)
  line(db, 'syncs', "#{s1},#{s2},#{s3}")
  line(db, 'published', published.to_s)
  line(db, 'idle', value_of(conn.exec('SELECT 1', [])))
end

def run_ends(conn, db)
  conn.pipeline_begin
  conn.pipeline_exec('SELECT 1/0', [])
  conn.pipeline_sync
  conn.pipeline_exec('SELECT 9', [])
  conn.pipeline_sync
  first = value_of(take_one(conn))
  read_sync(conn)
  second = value_of(take_one(conn))
  read_sync(conn)
  conn.pipeline_finish
  line(db, 'first', first)
  line(db, 'after-first', second)
  conn.pipeline_begin
  conn.pipeline_exec('SELECT 8', [])
  conn.pipeline_sync
  conn.pipeline_exec('SELECT 1/0', [])
  conn.pipeline_sync
  conn.pipeline_exec('SELECT 1', [])
  conn.pipeline_sync
  left = value_of(take_one(conn))
  read_sync(conn)
  mid = value_of(take_one(conn))
  read_sync(conn)
  right = value_of(take_one(conn))
  read_sync(conn)
  conn.pipeline_finish
  line(db, 'last-left', left)
  line(db, 'last-mid', mid)
  line(db, 'last-right', right)
end

def exec_ddl(conn, sql)
  conn.exec(sql, [])
end

def run_preload(conn, db)
  exec_ddl(conn, 'DROP TABLE IF EXISTS kiln_pipe_post')
  exec_ddl(conn, 'DROP TABLE IF EXISTS kiln_pipe_tag')
  exec_ddl(conn, 'DROP TABLE IF EXISTS kiln_pipe_miss')
  exec_ddl(conn, 'DROP TABLE IF EXISTS kiln_pipe_user')
  exec_ddl(conn, 'CREATE TABLE kiln_pipe_user (id INT NOT NULL, name VARCHAR(40) NOT NULL, PRIMARY KEY (id))')
  exec_ddl(conn,
           'CREATE TABLE kiln_pipe_post (id INT NOT NULL, user_id INT NOT NULL, title VARCHAR(40) NOT NULL, PRIMARY KEY (id))')
  exec_ddl(conn,
           'CREATE TABLE kiln_pipe_tag (id INT NOT NULL, user_id INT NOT NULL, label VARCHAR(40) NOT NULL, PRIMARY KEY (id))')
  PipeUser.define_table(:postgres, 'kiln_pipe_user', %w[id name], ['id'], 'u')
  PipePost.define_table(:postgres, 'kiln_pipe_post', %w[id user_id title], ['id'], 'p')
  PipeTag.define_table(:postgres, 'kiln_pipe_tag', %w[id user_id label], ['id'], 'g')
  PipeMiss.define_table(:postgres, 'kiln_pipe_miss', %w[id user_id], ['id'], 'm')
  PipeUser.has_many(:posts, PipePost, 'user_id')
  PipeUser.has_many(:missing, PipeMiss, 'user_id')
  PipeUser.has_many(:tags, PipeTag, 'user_id')
  PipeUser.import([{ 'id' => 1, 'name' => 'ada' }])
  PipePost.import([{ 'id' => 1, 'user_id' => 1, 'title' => 'a' }])
  PipeTag.import([{ 'id' => 1, 'user_id' => 1, 'label' => 'x' }])
  failed = 'open'
  begin
    PipeUser.all.preload(:posts).preload(:missing).preload(:tags).models
    failed = 'published'
  rescue Kiln::DB::Error
    failed = 'failed'
  end
  left = PipeUser.all.count
  exec_ddl(conn, 'DROP TABLE IF EXISTS kiln_pipe_post')
  exec_ddl(conn, 'DROP TABLE IF EXISTS kiln_pipe_tag')
  exec_ddl(conn, 'DROP TABLE IF EXISTS kiln_pipe_miss')
  exec_ddl(conn, 'DROP TABLE IF EXISTS kiln_pipe_user')
  line(db, 'preload', failed)
  line(db, 'preload-left', left.to_s)
end

class PipeUser < Kiln::DB::Model
end

class PipePost < Kiln::DB::Model
end

class PipeTag < Kiln::DB::Model
end

class PipeMiss < Kiln::DB::Model
end

def run_db(db, host, port, user, password, database, ca_path, tls_name)
  conn = Kiln::DB::Conn.open(Kiln::DB::Native::KIND_PG, host, port, user, password, database, ca_path, tls_name)
  Kiln::DB::Scope.use(conn)
  run_groups(conn, db)
  run_ends(conn, db)
  run_preload(conn, db)
  conn.close
end

path = 'build/db-runtime/session.env'
unless File.exist?(path)
  print "blocked pipeline-group\n"
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
print "ok pipeline-group\n"
