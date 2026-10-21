require 'kiln/db'
require 'test/db/support'

Thread.current

class GateUser < Kiln::DB::Model
end

class GatePost < Kiln::DB::Model
end

class GateMail < Kiln::DB::Model
end

class HookUser < Kiln::DB::Model
  def validate
    name = @attrs['name']
    return 'blank' if name.nil? || name == ''

    nil
  end

  def before_save
    HookUser.keep('b')
    nil
  end

  def after_save
    HookUser.keep('a')
    nil
  end

  class << self
    def reset
      @marks = ''
    end

    def keep(text)
      @marks = '' if @marks.nil?
      @marks += text
    end

    def kept
      return '' if @marks.nil?

      @marks
    end
  end
end

def exec_ddl(conn, sql)
  conn.exec(sql, [])
end

def drop_all(conn)
  exec_ddl(conn, 'DROP TABLE IF EXISTS kiln_gate_orm_post')
  exec_ddl(conn, 'DROP TABLE IF EXISTS kiln_gate_orm_mail')
  exec_ddl(conn, 'DROP TABLE IF EXISTS kiln_gate_orm_user')
end

def create_all(conn, dialect)
  user_sql = 'CREATE TABLE kiln_gate_orm_user (id INT NOT NULL, name VARCHAR(40) NOT NULL, PRIMARY KEY (id))'
  post_sql = 'CREATE TABLE kiln_gate_orm_post (id INT NOT NULL, user_id INT NOT NULL, title VARCHAR(40) NOT NULL, PRIMARY KEY (id))'
  mail_sql = 'CREATE TABLE kiln_gate_orm_mail (id INT NOT NULL, email VARCHAR(40) NOT NULL, name VARCHAR(40) NOT NULL, PRIMARY KEY (id), UNIQUE (email))'
  if dialect == :mysql
    user_sql += ' ENGINE=InnoDB'
    post_sql += ' ENGINE=InnoDB'
    mail_sql += ' ENGINE=InnoDB'
  end
  exec_ddl(conn, user_sql)
  exec_ddl(conn, post_sql)
  exec_ddl(conn, mail_sql)
end

def define_models(dialect)
  GateUser.define_table(dialect, 'kiln_gate_orm_user', %w[id name], ['id'], 'u')
  GatePost.define_table(dialect, 'kiln_gate_orm_post', %w[id user_id title], ['id'], 'p')
  GateMail.define_table(dialect, 'kiln_gate_orm_mail', %w[id email name], ['id'], 'm')
  HookUser.define_table(dialect, 'kiln_gate_orm_user', %w[id name], ['id'], 'h')
  GateUser.has_many(:posts, GatePost, 'user_id')
  GatePost.belongs_to(:user, GateUser, 'user_id')
end

def line(db, label, value)
  print db
  print ' '
  print label
  print ' '
  print value
  print "\n"
end

def assoc_counts(rows)
  text = ''
  i = 0
  while i < rows.length
    text += ',' if i.positive?
    text += rows[i].assoc(:posts).length.to_s
    i += 1
  end
  text
end

def run_db(db, kind, host, port, user, password, database, ca_path, tls_name)
  conn = Kiln::DB::Conn.open(kind, host, port, user, password, database, ca_path, tls_name)
  Kiln::DB::Scope.use(conn)
  define_models(conn.dialect)
  drop_all(conn)
  create_all(conn, conn.dialect)
  GateUser.import([{ 'id' => 1, 'name' => 'ada' }, { 'id' => 2, 'name' => 'bea' }, { 'id' => 3, 'name' => 'cy' }])
  GatePost.import([
                    { 'id' => 1, 'user_id' => 1, 'title' => 'a' },
                    { 'id' => 2, 'user_id' => 1, 'title' => 'b' },
                    { 'id' => 3, 'user_id' => 2, 'title' => 'c' }
                  ])
  loaded = GateUser.all.order(GateUser.col('id').asc).preload(:posts).models
  line(db, 'preload', assoc_counts(loaded))
  begin
    GateUser.all.models[0].assoc(:posts)
    line(db, 'unloaded', 'miss')
  rescue Kiln::DB::NotLoaded
    line(db, 'unloaded', 'blocked')
  end
  begin
    GateUser.all.preload(:posts, GatePost.all.limit(1)).models
    line(db, 'limit', 'miss')
  rescue Kiln::DB::Unsupported
    line(db, 'limit', 'blocked')
  end
  capped = GateUser.all.order(GateUser.col('id').asc).preload(:posts,
                                                              GatePost.all.order(GatePost.col('id').asc).limit(1)).models
  line(db, 'cap', "#{capped[0].assoc(:posts).length} #{capped[0].assoc(:posts)[0].attrs['title']}")
  owned = GatePost.all.order(GatePost.col('id').asc).preload(:user).models
  line(db, 'owner', owned[0].assoc(:user).attrs['name'])
  updated = GateUser.import([{ 'id' => 1, 'name' => 'ADA' }], { on_duplicate_key_update: true })
  kept = GateUser.all.where(GateUser.col('id').eq(1)).pluck(GateUser.col('name'))
  line(db, 'update', "#{updated.input_status(0)} #{kept[0]}")
  HookUser.reset
  begin
    HookUser.new({ 'id' => 5, 'name' => '' }).save!
    line(db, 'invalid', 'miss')
  rescue Kiln::DB::RecordInvalid
    absent = HookUser.all.where(HookUser.col('id').eq(5)).count
    line(db, 'invalid', "raised #{absent}")
  end
  line(db, 'save-false', HookUser.new({ 'id' => 5, 'name' => '' }).save ? 'miss' : 'false')
  HookUser.import([{ 'id' => 7, 'name' => 'io' }])
  line(db, 'hook-import', HookUser.kept == '' ? 'quiet' : HookUser.kept)
  made = HookUser.new({ 'id' => 6, 'name' => 'ed' })
  made.save
  found = HookUser.all.where(HookUser.col('id').eq(6)).models
  found[0].assign('name', 'ed2')
  found[0].save
  got = HookUser.all.where(HookUser.col('id').eq(6)).pluck(HookUser.col('name'))
  line(db, 'saved', "#{got[0]} #{HookUser.kept}")
  if conn.dialect == :postgres
    mailed = GateMail.import([{ 'id' => 1, 'email' => 'a@b.c', 'name' => 'a' }], { on_duplicate_key_update: true })
    left = GateMail.all.count
    line(db, 'mail', "#{mailed.input_status(0)} #{left}")
  else
    begin
      GateMail.import([{ 'id' => 1, 'email' => 'a@b.c', 'name' => 'a' }], { on_duplicate_key_update: true })
      line(db, 'mail', 'miss')
    rescue Kiln::DB::AmbiguousConflict
      left = GateMail.all.count
      line(db, 'mail', "blocked #{left}")
    end
  end
  drop_all(conn)
  conn.close
  Kiln::DB::Scope.use(nil)
end

path = 'build/db-runtime/session.env'
text = File.read(path)
ca_path = "#{env_line(text, 'KILN_DB_CONFIG_DIR')}/ca.crt"
tls_name = env_line(text, 'KILN_DB_TLS_NAME')
pg_user = env_line(text, 'KILN_DB_PG_USER')
pg_password = env_line(text, 'KILN_DB_PG_PASSWORD')
pg_db = env_line(text, 'KILN_DB_PG_DB')
my_user = env_line(text, 'KILN_DB_MY_USER')
my_password = env_line(text, 'KILN_DB_MY_PASSWORD')
my_db = env_line(text, 'KILN_DB_MY_DB')
print "configured\n"
run_db('pg17', Kiln::DB::Native::KIND_PG, env_line(text, 'DB_PG17_HOST'), env_line(text, 'DB_PG17_PORT').to_i, pg_user,
       pg_password, pg_db, ca_path, tls_name)
run_db('pg18', Kiln::DB::Native::KIND_PG, env_line(text, 'DB_PG18_HOST'), env_line(text, 'DB_PG18_PORT').to_i, pg_user,
       pg_password, pg_db, ca_path, tls_name)
run_db('mysql84', Kiln::DB::Native::KIND_MY, env_line(text, 'DB_MY_HOST'), env_line(text, 'DB_MY_PORT').to_i, my_user,
       my_password, my_db, ca_path, tls_name)
run_db('mariadb114', Kiln::DB::Native::KIND_MY, env_line(text, 'DB_MARIA_HOST'), env_line(text, 'DB_MARIA_PORT').to_i,
       my_user, my_password, my_db, ca_path, tls_name)
print "ok gate-orm\n"
