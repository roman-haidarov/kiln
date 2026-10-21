require 'kiln/db'
require 'test/db/support'

Thread.current

def need(label, cond)
  return if cond

  print label
  print "\n"
  raise label
end

class GateUser < Kiln::DB::Model
end

class GatePost < Kiln::DB::Model
end

class GateTag < Kiln::DB::Model
end

def exec_ddl(conn, sql)
  conn.exec(sql, [])
end

def drop_all(conn)
  exec_ddl(conn, 'DROP TABLE IF EXISTS kiln_gate_c_post')
  exec_ddl(conn, 'DROP TABLE IF EXISTS kiln_gate_c_tag')
  exec_ddl(conn, 'DROP TABLE IF EXISTS kiln_gate_c_user')
end

def create_all(conn, dialect)
  user_sql = 'CREATE TABLE kiln_gate_c_user (id INT NOT NULL, name VARCHAR(40) NOT NULL, PRIMARY KEY (id))'
  post_sql = 'CREATE TABLE kiln_gate_c_post (id INT NOT NULL, user_id INT NOT NULL, title VARCHAR(40) NOT NULL, PRIMARY KEY (id))'
  tag_sql = 'CREATE TABLE kiln_gate_c_tag (id INT NOT NULL, label VARCHAR(40) NOT NULL, PRIMARY KEY (id))'
  if dialect == :mysql
    user_sql += ' ENGINE=InnoDB'
    post_sql += ' ENGINE=InnoDB'
    tag_sql += ' ENGINE=InnoDB'
  end
  exec_ddl(conn, user_sql)
  exec_ddl(conn, post_sql)
  exec_ddl(conn, tag_sql)
end

def define_models(dialect)
  GateUser.define_table(dialect, 'kiln_gate_c_user', %w[id name], ['id'], 'u')
  GatePost.define_table(dialect, 'kiln_gate_c_post', %w[id user_id title], ['id'], 'p')
  GateTag.define_table(dialect, 'kiln_gate_c_tag', %w[id label], ['id'], 'g')
end

def line(db, label, value)
  print db
  print ' '
  print label
  print ' '
  print value
  print "\n"
end

def sort_text(list)
  out = []
  i = 0
  while i < list.length
    value = list[i]
    out << value
    j = out.length - 1
    while j.positive? && out[j - 1] > value
      out[j] = out[j - 1]
      j -= 1
    end
    out[j] = value
    i += 1
  end
  text = ''
  i = 0
  while i < out.length
    text += ',' if i.positive?
    text += out[i]
    i += 1
  end
  text
end

def cell_text(value)
  return '' if value.nil?

  value.to_s
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
  GateTag.import([{ 'id' => 1, 'label' => 'x' }, { 'id' => 4, 'label' => 'y' }])
  joined = GateUser.all.inner_join(GatePost, on: GatePost.col('user_id').eq(GateUser.col('id'))).count
  left = GateUser.all.left_join(GatePost, on: GatePost.col('user_id').eq(GateUser.col('id'))).count
  grouped = GatePost.all.group(GatePost.col('user_id')).count
  parts = []
  grouped.each { |key, count| parts << "#{key[0]}=#{count}" }
  plucked = GateUser.all.order(GateUser.col('id').asc).pluck(GateUser.col('name'))
  names = ''
  i = 0
  while i < plucked.length
    names += ',' if i.positive?
    names += plucked[i]
    i += 1
  end
  existed = GateUser.all.where_exists(GatePost.all.where(GatePost.col('user_id').eq(GateUser.col('id')))).count
  from_n = GateUser.all.from(GateUser.all.where(GateUser.col('id').eq(1))).count
  full_rows = GateUser.all.full_join(GateTag, on: GateTag.col('id').eq(GateUser.col('id'))).select(GateUser.col('id'),
                                                                                                   GateTag.col('id')).to_a
  full_text = []
  i = 0
  while i < full_rows.length
    full_text << "#{cell_text(full_rows[i][0])}:#{cell_text(full_rows[i][1])}"
    i += 1
  end
  begin
    Kiln::DB.transaction do
      GateUser.import([{ 'id' => 9, 'name' => 'zz' }])
      raise 'rollback'
    end
    line(db, 'tx', 'miss')
  rescue RuntimeError
    line(db, 'tx', 'rollback')
  end
  rolled = GateUser.all.count
  got = GateUser.import([{ 'id' => 8, 'name' => 'dee' }], { returning: true })
  cols = Kiln::DB::Schema.columns(conn, 'kiln_gate_c_user')
  col_names = ''
  i = 0
  while i < cols.length
    col_names += ',' if i.positive?
    col_names += cols[i][0]
    i += 1
  end
  keys = Kiln::DB::Schema.primary_key(conn, 'kiln_gate_c_user')
  key_names = []
  i = 0
  while i < keys.length
    key_names << keys[i][0]
    i += 1
  end
  src = Kiln::DB::Generate.models(conn.dialect,
                                  [{ name: 'kiln_gate_c_user', columns: %w[id name], primary_key: key_names }])
  empty = GateUser.import([])
  line(db, 'join', joined.to_s)
  line(db, 'left', left.to_s)
  line(db, 'group', sort_text(parts))
  line(db, 'pluck', names)
  line(db, 'exists', existed.to_s)
  line(db, 'from', from_n.to_s)
  line(db, 'full', sort_text(full_text))
  line(db, 'rolled', rolled.to_s)
  line(db, 'return', "#{got.input_status(0)} #{got.returned[0][0]}")
  line(db, 'schema', col_names)
  line(db, 'pk', sort_text(key_names))
  line(db, 'gen', src.include?('kiln_gate_c_user') && src.include?('define_table') ? 'yes' : 'no')
  line(db, 'empty', "#{empty.state} #{empty.length}")
  begin
    GateUser.import([{ 'id' => 9, 'name' => 'z' }], { nope: true })
    line(db, 'option', 'miss')
  rescue ArgumentError
    line(db, 'option', 'rejected')
  end
  if conn.dialect == :postgres
    again = GateUser.import([{ 'id' => 1, 'name' => 'nope' }], { on_duplicate_key_ignore: true, returning: true })
    kept = GateUser.all.where(GateUser.col('id').eq(1)).pluck(GateUser.col('name'))
    line(db, 'ignore', "#{again.input_status(0)} #{kept[0]}")
  else
    begin
      GateUser.import([{ 'id' => 1, 'name' => 'nope' }], { on_duplicate_key_ignore: true })
      line(db, 'ignore', 'miss')
    rescue Kiln::DB::UnsafeImportSchema
      line(db, 'ignore', 'blocked')
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
print "ok gate-c\n"
