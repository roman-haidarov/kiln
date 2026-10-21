require 'kiln/db'
require 'test/db/support'

Thread.current

class User < Kiln::DB::Model
  def validate
    'name required' if attrs['name'].nil?
  end
end

class Post < Kiln::DB::Model
end

class Tag < Kiln::DB::Model
end

def show(db, label, value)
  print "#{db} #{label} => #{value.inspect}\n"
end

def create_doc_tables(conn)
  bool = conn.dialect == :postgres ? 'BOOLEAN' : 'TINYINT(1)'
  conn.exec('DROP TABLE IF EXISTS posts', [])
  conn.exec('DROP TABLE IF EXISTS tags', [])
  conn.exec('DROP TABLE IF EXISTS users', [])
  conn.exec("CREATE TABLE users (id INT PRIMARY KEY, name VARCHAR(40), active #{bool})", [])
  conn.exec('CREATE TABLE posts (id INT PRIMARY KEY, user_id INT, title VARCHAR(40))', [])
  conn.exec('CREATE TABLE tags (id INT PRIMARY KEY, label VARCHAR(40))', [])
end

def define_doc_models(d)
  User.define_table(d, 'users', %w[id name active], ['id'], 'u')
  Post.define_table(d, 'posts', %w[id user_id title], ['id'], 'p')
  Tag.define_table(d, 'tags', %w[id label], ['id'], 't')
  User.has_many(:posts, Post, 'user_id')
  Post.belongs_to(:user, User, 'user_id')
end

def seed_doc_models
  User.import([{ 'id' => 1, 'name' => 'Rebecca', 'active' => true }, { 'id' => 2, 'name' => 'Ada', 'active' => false },
               { 'id' => 3, 'name' => 'Leon', 'active' => true }])
  Post.import([{ 'id' => 10, 'user_id' => 1, 'title' => 'Notes' }, { 'id' => 11, 'user_id' => 1, 'title' => 'Draft' },
               { 'id' => 12, 'user_id' => 2, 'title' => 'Guide' }])
  Tag.import([{ 'id' => 1, 'label' => 'Alpha' }, { 'id' => 4, 'label' => 'Umbrella' }])
end

def show_doc_rows(db)
  users = User.all.order(User.col('id').asc).models
  show(db, 'attrs', users.map { |user| user.attrs })
  users = User.all.order(User.col('id').asc).preload(:posts).models
  show(db, 'preload', users.map { |user| user.assoc(:posts).map { |post| post.attrs['title'] } })
end

def show_doc_match_filters(db)
  show(db, 'active', User.all.where(User.col('active').eq(true)).order(User.col('name').asc).pluck(User.col('name')))
  show(db, 'or',
       User.all.where(User.col('active').eq(true).or(User.col('name').eq('Ada'))).order(User.col('id').asc).pluck(User.col('name')))
  show(db, 'between', User.all.where(User.col('id').between(1, 2)).order(User.col('id').asc).pluck(User.col('name')))
  show(db, 'in', User.all.where(User.col('id').in([1, 3])).order(User.col('id').asc).pluck(User.col('name')))
  show(db, 'not_in', User.all.where(User.col('id').not_in([1, 3])).pluck(User.col('name')))
  show(db, 'like', User.all.where(User.col('name').like('R%')).pluck(User.col('name')))
end

def show_doc_projection_filters(db)
  show(db, 'page', User.all.order(User.col('id').asc).limit(1).offset(1).pluck(User.col('name')))
  show(db, 'select', User.all.order(User.col('id').asc).select(User.col('name'), User.col('active')).to_a)
  show(db, 'pluck2', User.all.order(User.col('id').asc).pluck(User.col('id'), User.col('name')))
  show(db, 'first', User.all.order(User.col('id').asc).select(User.col('name')).first.get('name'))
  show(db, 'collect', User.all.order(User.col('id').asc).collect { |row| row.get('name') })
  show(db, 'map', User.all.order(User.col('id').asc).select(User.col('id'), User.col('name')).map { |row| row[1] })
end

def show_doc_counts(db)
  show(db, 'count', User.all.count)
  show(db, 'count_active', User.all.where(User.col('active').eq(true)).count)
  show(db, 'exists', User.all.where(User.col('active').eq(true)).exists?)
  show(db, 'from', User.all.from(User.all.where(User.col('id').eq(1))).count)
  show(db, 'ids', User.all.order(User.col('id').asc).ids)
  show(db, 'pick', User.all.pick(User.col('name')))
end

def show_doc_join_results(db)
  show(db, 'left_join',
       User.all.left_join(Post, on: Post.col('user_id').eq(User.col('id'))).order(User.col('id').asc, Post.col('id').asc).select(User.col('name'), Post.col('title')).to_a)
  show(db, 'join_count', User.all.inner_join(Post, on: Post.col('user_id').eq(User.col('id'))).count)
  show(db, 'count_root', User.all.inner_join(Post, on: Post.col('user_id').eq(User.col('id'))).count_root)
  show(db, 'self_join', User.all.join_as(User, 'u2', on: User.col('id').eq(Kiln::DB::Col.new('u2', 'id'))).count)
  show(db, 'right_join',
       User.all.right_join(Tag, on: Tag.col('id').eq(User.col('id'))).order(Tag.col('id').asc).select(User.col('name'), Tag.col('label')).to_a)
  show(db, 'full_join', User.all.full_join(Tag, on: Tag.col('id').eq(User.col('id'))).count)
  show(db, 'cross_join', User.all.cross_join(Tag).count)
end

def show_doc_subqueries(db)
  show(db, 'where_exists',
       User.all.where_exists(Post.all.where(Post.col('user_id').eq(User.col('id')))).order(User.col('id').asc).pluck(User.col('name')))
  show(db, 'where_missing',
       User.all.where_missing(Post.all.where(Post.col('user_id').eq(User.col('id')))).order(User.col('id').asc).pluck(User.col('name')))
  show(db, 'group', Post.all.group(Post.col('user_id')).order(Post.col('user_id').asc).count.to_a)
  show(db, 'having', Post.all.group(Post.col('user_id')).having(Post.col('user_id').eq(1)).count.to_a)
end

def show_doc_writes(db, conn, d)
  show(db, 'count_user', Post.all.where(Post.col('user_id').eq(1)).count)
  show(db, 'sum', Post.all.sum(Post.col('id')).to_s)
  sql = d == :postgres ? 'SELECT id, name FROM users WHERE active = $1' : 'SELECT id, name FROM users WHERE active = ?'
  show(db, 'exec', Kiln::DB::Scope.lease { |c| c.exec(sql, [true]) })
  user = User.new({ 'id' => 5, 'name' => 'Leon', 'active' => true })
  user.save!
  user.assign('name', 'Chris Redfield')
  user.save!
  show(db, 'saved', User.all.where(User.col('id').eq(5)).pluck(User.col('name')))
  result = User.import([{ 'id' => 6, 'name' => 'Leon', 'active' => true },
                        { id: 7, name: 'Chris', active: true }])
  show(db, 'import', [result.state, result.length, result.input_status(0)])
  conn.exec('DROP TABLE posts', [])
  conn.exec('DROP TABLE tags', [])
  conn.exec('DROP TABLE users', [])
end

def docs(db, conn)
  d = conn.dialect
  create_doc_tables(conn)
  define_doc_models(d)
  seed_doc_models
  show_doc_rows(db)
  show_doc_match_filters(db)
  show_doc_projection_filters(db)
  show_doc_counts(db)
  show_doc_join_results(db)
  show_doc_subqueries(db)
  show_doc_writes(db, conn, d)
end

text = File.read('build/db-runtime/session.env')
ca = "#{env_line(text, 'KILN_DB_CONFIG_DIR')}/ca.crt"
tls = env_line(text, 'KILN_DB_TLS_NAME')
pg = Kiln::DB::Conn.open(Kiln::DB::Native::KIND_PG, env_line(text, 'DB_PG17_HOST'), env_line(text, 'DB_PG17_PORT').to_i,
                         env_line(text, 'KILN_DB_PG_USER'), env_line(text, 'KILN_DB_PG_PASSWORD'), env_line(text, 'KILN_DB_PG_DB'), ca, tls)
Kiln::DB::Scope.use(pg)
docs('pg', pg)
pg.close
my = Kiln::DB::Conn.open(Kiln::DB::Native::KIND_MY, env_line(text, 'DB_MY_HOST'), env_line(text, 'DB_MY_PORT').to_i,
                         env_line(text, 'KILN_DB_MY_USER'), env_line(text, 'KILN_DB_MY_PASSWORD'), env_line(text, 'KILN_DB_MY_DB'), ca, tls)
Kiln::DB::Scope.use(my)
docs('mysql', my)
my.close
Kiln::DB::Scope.use(nil)
