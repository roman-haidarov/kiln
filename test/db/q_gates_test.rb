require 'kiln/db'
require 'test/db/support'

Thread.current

module QGateState
  class << self
    attr_accessor :hook
  end
end

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

def cell_text(value)
  return '' if value.nil?

  value.to_s
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

class QUser < Kiln::DB::Model
  def validate
    return 'bad' if @attrs['name'] == 'bad'

    nil
  end

  def before_save
    QGateState.hook = 1
    nil
  end
end

class QPost < Kiln::DB::Model
end

class QTag < Kiln::DB::Model
end

class QBag < Kiln::DB::Model
end

class QLink < Kiln::DB::Model
end

class QNum < Kiln::DB::Model
end

class QPair < Kiln::DB::Model
end

class QStamp < Kiln::DB::Model
end

class QLock < Kiln::DB::Model
end

def exec_ddl(conn, sql)
  conn.exec(sql, [])
end

def drop_all(conn)
  exec_ddl(conn, 'DROP TABLE IF EXISTS kiln_q_post')
  exec_ddl(conn, 'DROP TABLE IF EXISTS kiln_q_tag')
  exec_ddl(conn, 'DROP TABLE IF EXISTS kiln_q_link')
  exec_ddl(conn, 'DROP TABLE IF EXISTS kiln_q_bag')
  exec_ddl(conn, 'DROP TABLE IF EXISTS kiln_q_num')
  exec_ddl(conn, 'DROP TABLE IF EXISTS kiln_q_pair')
  exec_ddl(conn, 'DROP TABLE IF EXISTS kiln_q_stamp')
  exec_ddl(conn, 'DROP TABLE IF EXISTS kiln_q_lock')
  exec_ddl(conn, 'DROP TABLE IF EXISTS kiln_q_user')
end

def create_all(conn, dialect)
  engine = dialect == :mysql ? ' ENGINE=InnoDB' : ''
  num_n = 'BIGINT'
  num_d = dialect == :postgres ? 'NUMERIC(10,2)' : 'DECIMAL(10,2)'
  stamp = 'TIMESTAMP NULL'
  exec_ddl(conn, "CREATE TABLE kiln_q_user (id INT NOT NULL, name VARCHAR(40) NOT NULL, PRIMARY KEY (id))#{engine}")
  exec_ddl(conn,
           "CREATE TABLE kiln_q_post (id INT NOT NULL, user_id INT NOT NULL, title VARCHAR(40) NOT NULL, PRIMARY KEY (id))#{engine}")
  exec_ddl(conn, "CREATE TABLE kiln_q_tag (id INT NOT NULL, label VARCHAR(40) NOT NULL, PRIMARY KEY (id))#{engine}")
  exec_ddl(conn, "CREATE TABLE kiln_q_bag (id INT NOT NULL, k INT NOT NULL, PRIMARY KEY (id))#{engine}")
  exec_ddl(conn,
           "CREATE TABLE kiln_q_link (id INT NOT NULL, user_id INT NOT NULL, bag_id INT NOT NULL, PRIMARY KEY (id))#{engine}")
  exec_ddl(conn,
           "CREATE TABLE kiln_q_num (id INT NOT NULL, n #{num_n} NULL, d #{num_d} NULL, PRIMARY KEY (id))#{engine}")
  exec_ddl(conn, "CREATE TABLE kiln_q_pair (id INT NOT NULL, n INT NOT NULL, PRIMARY KEY (id, n))#{engine}")
  exec_ddl(conn,
           "CREATE TABLE kiln_q_stamp (id INT NOT NULL, name VARCHAR(40) NOT NULL, created_at #{stamp}, PRIMARY KEY (id))#{engine}")
  exec_ddl(conn, "CREATE TABLE kiln_q_lock (id INT NOT NULL, name VARCHAR(40) NOT NULL, PRIMARY KEY (id))#{engine}")
end

def define_models(dialect)
  QUser.define_table(dialect, 'kiln_q_user', %w[id name], ['id'], 'u')
  QPost.define_table(dialect, 'kiln_q_post', %w[id user_id title], ['id'], 'p')
  QTag.define_table(dialect, 'kiln_q_tag', %w[id label], ['id'], 'g')
  QBag.define_table(dialect, 'kiln_q_bag', %w[id k], ['id'], 'b')
  QLink.define_table(dialect, 'kiln_q_link', %w[id user_id bag_id], ['id'], 'l')
  QNum.define_table(dialect, 'kiln_q_num', %w[id n d], ['id'], 'n')
  QPair.define_table(dialect, 'kiln_q_pair', %w[id n], %w[id n], 'r')
  QStamp.define_table(dialect, 'kiln_q_stamp', %w[id name created_at], ['id'], 's')
  QLock.define_table(dialect, 'kiln_q_lock', %w[id name], ['id'], 'k')
end

def join_on
  QPost.col('user_id').eq(QUser.col('id'))
end

def run_db(db, kind, host, port, user, password, database, ca_path, tls_name)
  conn = Kiln::DB::Conn.open(kind, host, port, user, password, database, ca_path, tls_name)
  Kiln::DB::Scope.use(conn)
  define_models(conn.dialect)
  drop_all(conn)
  create_all(conn, conn.dialect)
  QUser.import([{ 'id' => 1, 'name' => 'ada' }, { 'id' => 2, 'name' => 'bea' }, { 'id' => 3, 'name' => 'cy' }])
  QPost.import([
                 { 'id' => 1, 'user_id' => 1, 'title' => 'a' },
                 { 'id' => 2, 'user_id' => 1, 'title' => 'b' },
                 { 'id' => 3, 'user_id' => 2, 'title' => 'c' }
               ])
  QTag.import([{ 'id' => 1, 'label' => 'x' }, { 'id' => 4, 'label' => 'y' }])
  QBag.import([{ 'id' => 1, 'k' => 1 }, { 'id' => 2, 'k' => 1 }, { 'id' => 3, 'k' => 9 }])
  QLink.import([{ 'id' => 1, 'user_id' => 1, 'bag_id' => 1 }])
  QNum.import([
                { 'id' => 1, 'n' => '10', 'd' => '1.50' },
                { 'id' => 2, 'n' => nil, 'd' => '2.25' },
                { 'id' => 3, 'n' => '20', 'd' => nil },
                { 'id' => 4, 'n' => '9223372036854775807', 'd' => '0.10' }
              ])
  QPair.import([{ 'id' => 1, 'n' => 2 }])
  QGateState.hook = 0
  q1 = QUser.all.where(QUser.col('name').eq('ada')).count
  picked = QUser.all.order(QUser.col('id').asc).pluck(QUser.col('name'))
  one = QUser.all.pick(QUser.col('name'))
  ids = QUser.all.ids
  distinct_n = QUser.all.select(QUser.col('name')).distinct.count
  big = QNum.all.where(QNum.col('id').eq(4)).pluck(QNum.col('n'))
  inner = QUser.all.inner_join(QPost, on: join_on).count
  left = QUser.all.left_join(QPost, on: join_on).count
  right = QUser.all.right_join(QTag, on: QTag.col('id').eq(QUser.col('id'))).count
  cross = QUser.all.cross_join(QTag).count
  existed = QUser.all.where_exists(QPost.all.where(QPost.col('user_id').eq(QUser.col('id')))).count
  missing = QUser.all.where_missing(QPost.all.where(QPost.col('user_id').eq(QUser.col('id')))).count
  self_n = QUser.all.join_as(QUser, 'u2', on: QUser.col('id').eq(Kiln::DB::Col.new('u2', 'id'))).count
  through = QUser.all.through(QPost, QTag, QPost.col('user_id').eq(QUser.col('id')),
                              QTag.col('id').eq(QPost.col('id'))).count
  pair = QPair.all.ids
  bag_rows = QUser.all.full_join(QBag, on: QBag.col('k').eq(QUser.col('id'))).select(QUser.col('id'),
                                                                                     QBag.col('id')).to_a
  bag_text = []
  i = 0
  while i < bag_rows.length
    bag_text << "#{cell_text(bag_rows[i][0])}:#{cell_text(bag_rows[i][1])}"
    i += 1
  end
  linked = QUser.all.full_join(QBag, on: QBag.col('k').eq(QUser.col('id'))).where_exists(
    QLink.all.where(QLink.col('user_id').eq(QUser.col('id')).and(QLink.col('bag_id').eq(QBag.col('id'))))
  ).select(QUser.col('id'), QBag.col('id')).to_a
  link_text = []
  i = 0
  while i < linked.length
    link_text << "#{cell_text(linked[i][0])}:#{cell_text(linked[i][1])}"
    i += 1
  end
  grouped = QPost.all.group(QPost.col('user_id')).having(QPost.col('user_id').eq(1)).count
  empty_sum = QNum.all.where(QNum.col('id').eq(-1)).sum(QNum.col('n'))
  small_sum = QNum.all.where(QNum.col('id').in([1, 3])).sum(QNum.col('n'))
  dec_sum = QNum.all.sum(QNum.col('d'))
  big_sum = QNum.all.sum(QNum.col('n'))
  empty_min = QNum.all.where(QNum.col('id').eq(-1)).min(QNum.col('n'))
  name_min = QUser.all.min(QUser.col('name'))
  from_n = QUser.all.from(QUser.all.where(QUser.col('id').eq(1))).count
  in_empty = QUser.all.where(QUser.col('id').in([])).count
  in_null = QNum.all.where(QNum.col('n').in(['10'])).count
  not_in_null = QNum.all.where(QNum.col('n').not_in(['10'])).count
  collected = QUser.all.order(QUser.col('id').asc).collect { |row| row.get('name') }
  mapped = QUser.all.order(QUser.col('id').asc).map { |row| row[0] }
  listed = QUser.all.order(QUser.col('id').asc).to_a
  bad = QUser.import([QUser.new({ 'id' => 20, 'name' => 'bad' })])
  partial = QUser.import([QUser.new({ 'id' => 21, 'name' => 'zed' }), QUser.new({ 'id' => 22, 'name' => 'bad' })],
                         { all_or_none: false })
  bang = 'open'
  begin
    QUser.import!([QUser.new({ 'id' => 23, 'name' => 'bad' })])
    bang = 'passed'
  rescue Kiln::DB::RecordInvalid
    bang = 'raised'
  end
  hook = QGateState.hook
  QStamp.import([{ 'id' => 1, 'name' => 'now' }], { timestamps: true })
  stamped = QStamp.all.pluck(QStamp.col('created_at'))
  ts = stamped.length == 1 && !stamped[0].nil? ? 'yes' : 'no'
  mode = ''
  if conn.dialect == :mysql
    mode = conn.exec('SELECT @@session.sql_mode', [])[0][0].to_s
    exec_ddl(conn, "SET SESSION sql_mode = ''")
  end
  session = 'pg'
  if conn.dialect == :mysql
    begin
      QUser.import([{ 'id' => 30, 'name' => 'mode' }])
      session = 'open'
    rescue Kiln::DB::UnsafeImportSchema
      session = 'blocked'
    end
    exec_ddl(conn, "SET SESSION sql_mode = '#{mode}'")
  end
  ignore = 'pg'
  if conn.dialect == :mysql
    QUser.import([{ 'id' => 1, 'name' => 'ada' }], { on_duplicate_key_ignore: true })
    ignore = 'passed'
  end
  warned = 'pg'
  if conn.dialect == :mysql
    conn.exec("DO CAST('abc' AS UNSIGNED)", [])
    warned = conn.warning_count.positive? ? 'yes' : 'no'
  end
  held = Kiln::DB::Conn.open(kind, host, port, user, password, database, ca_path, tls_name)
  exec_ddl(conn, 'INSERT INTO kiln_q_lock (id, name) VALUES (1, \'a\')')
  conn.transaction_open
  conn.exec('SELECT id FROM kiln_q_lock WHERE id = 1 FOR UPDATE', [])
  if conn.dialect == :mysql
    held.exec('SET SESSION innodb_lock_wait_timeout = 1', [])
  else
    held.exec("SET lock_timeout = '1s'", [])
  end
  held.transaction_open
  lock = 'open'
  begin
    held.exec('SELECT id FROM kiln_q_lock WHERE id = 1 FOR UPDATE', [])
    lock = 'open'
  rescue Kiln::DB::Deadlock
    lock = 'deadlock'
  rescue Kiln::DB::LockWaitTimeout
    lock = 'lockwait'
  rescue Kiln::DB::Error
    lock = 'error'
  end
  held.transaction_fail
  conn.transaction_fail
  held.close
  users = QUser.all.count
  line(db, 'q1', q1.to_s)
  line(db, 'q2', "#{picked.length} #{one} #{ids.length} #{distinct_n} #{big[0]}")
  line(db, 'q3', "#{inner} #{left} #{right} #{cross} #{existed} #{missing} #{self_n} #{through} #{pair[0].length}")
  line(db, 'q4', "#{sort_text(bag_text)} #{sort_text(link_text)}")
  sums = [
    empty_sum.nil? ? 'nil' : 'bad',
    small_sum == Kiln::DB::ExactDecimal.parse('30') ? '30' : 'bad',
    dec_sum == Kiln::DB::ExactDecimal.parse('3.85') ? '3.85' : dec_sum.to_s,
    big_sum == Kiln::DB::ExactDecimal.parse('9223372036854775837') ? 'big' : 'bad',
    empty_min.nil? ? 'nil' : 'bad',
    name_min.to_s,
    grouped.length.to_s
  ]
  line(db, 'q5', sums.join(' '))
  line(db, 'q6', "#{from_n} #{in_empty} #{in_null} #{not_in_null}")
  line(db, 'q7', "#{collected.length} #{mapped.length} #{listed.length}")
  line(db, 'q8', "#{bad.state} #{partial.state} #{users} #{bang} #{hook} #{ts}")
  line(db, 'q9', "#{session} #{ignore} #{warned} #{lock}")
  drop_all(conn)
  conn.close
end

path = 'build/db-runtime/session.env'
unless File.exist?(path)
  print "blocked q-gates\n"
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
print "ok q-gates\n"
