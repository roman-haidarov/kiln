require 'kiln/db'

Thread.current

def need(label, cond)
  return if cond

  print label
  print "\n"
  raise label
end

def show(label, relation)
  compiled = relation.compile(:rows)
  print label
  print ' '
  print compiled[0]
  print ' binds '
  print compiled[1].length
  print "\n"
end

def scan(path)
  text = File.read(path)
  need(path, !text.include?('MYSQL_BIND') && !text.include?('PGresult'))
end

class SqlUser < Kiln::DB::Model
end

class SqlPost < Kiln::DB::Model
end

class SqlTag < Kiln::DB::Model
end

class SqlComposite < Kiln::DB::Model
end

SqlUser.define_table(:postgres, 'users', %w[id name], ['id'], 'u')
SqlPost.define_table(:postgres, 'posts', %w[id user_id title], ['id'], 'p')
SqlTag.define_table(:postgres, 'tags', %w[id label], ['id'], 'g')
SqlComposite.define_table(:postgres, 'composite', %w[left_key right_key], %w[left_key right_key], 'c')

key_a = Kiln::DB::Import.input_key(SqlComposite, { 'left_key' => "a\x1fb", 'right_key' => 'c' })
key_b = Kiln::DB::Import.input_key(SqlComposite, { 'left_key' => 'a', 'right_key' => "b\x1fc" })
need('composite-key', key_a != key_b)
need('composite-output-key', key_a == Kiln::DB::Import.output_key(SqlComposite, ["a\x1fb", 'c']))
print "composite-key collision-free\n"

scan('kiln/db/sql.rb')
scan('kiln/db/relation.rb')
scan('kiln/db/expr.rb')
scan('kiln/db/batch.rb')
scan('kiln/db/model.rb')
scan('kiln/db/schema.rb')

show('pg-where', SqlUser.all.where(SqlUser.col('id').eq(1)))
show('pg-join',
     SqlUser.all.inner_join(SqlPost, on: SqlPost.col('user_id').eq(SqlUser.col('id'))).select(SqlUser.col('id'),
                                                                                              SqlPost.col('title')))
show('pg-left', SqlUser.all.left_join(SqlPost, on: SqlPost.col('user_id').eq(SqlUser.col('id'))))
show('pg-full',
     SqlUser.all.full_join(SqlTag, on: SqlTag.col('id').eq(SqlUser.col('id'))).select(SqlUser.col('id'),
                                                                                      SqlTag.col('label')))
show('pg-group', SqlPost.all.group(SqlPost.col('user_id')))
print 'pg-count '
print SqlPost.all.group(SqlPost.col('user_id')).compile(:count)[0]
print "\n"
show('pg-in', SqlUser.all.where(SqlUser.col('id').in([1, 2])))
show('pg-empty', SqlUser.all.where(SqlUser.col('id').in([])))
show('pg-exists', SqlUser.all.where_exists(SqlPost.all.where(SqlPost.col('user_id').eq(SqlUser.col('id')))))
show('pg-missing', SqlUser.all.where_missing(SqlPost.all.where(SqlPost.col('user_id').eq(SqlUser.col('id')))))
inner = SqlUser.all.where(SqlUser.col('id').eq(1)).select(SqlUser.col('id'), SqlUser.col('name'))
show('pg-from', SqlUser.all.from(inner).where(SqlUser.col('name').eq('ada')))
show('pg-self', SqlUser.all.join_as(SqlUser, 'u2', on: SqlUser.col('id').eq(Kiln::DB::Col.new('u2', 'id'))))
show('pg-through',
     SqlUser.all.through(SqlPost, SqlTag, SqlPost.col('user_id').eq(SqlUser.col('id')),
                         SqlTag.col('id').eq(SqlPost.col('id'))))
print 'pg-root '
print SqlUser.all.compile(:root)[0]
print "\n"

SqlUser.define_table(:mysql, 'users', %w[id name], ['id'], 'u')
SqlPost.define_table(:mysql, 'posts', %w[id user_id title], ['id'], 'p')
SqlTag.define_table(:mysql, 'tags', %w[id label], ['id'], 'g')
show('my-where', SqlUser.all.where(SqlUser.col('id').eq(1)))
show('my-full',
     SqlUser.all.full_join(SqlTag, on: SqlTag.col('id').eq(SqlUser.col('id'))).select(SqlUser.col('id'),
                                                                                      SqlTag.col('label')))
need('union', SqlUser.all.full_join(SqlTag, on: SqlTag.col('id').eq(SqlUser.col('id'))).to_sql.include?('UNION ALL'))
need('not-exists',
     SqlUser.all.full_join(SqlTag, on: SqlTag.col('id').eq(SqlUser.col('id'))).to_sql.include?('NOT EXISTS'))
full_exists = SqlUser.all.full_join(SqlTag, on: SqlTag.col('id').eq(SqlUser.col('id'))).where_exists(
  SqlPost.all.where(SqlPost.col('user_id').eq(SqlUser.col('id')).and(SqlPost.col('id').eq(SqlTag.col('id'))))
)
show('my-full-exists', full_exists)
exists_sql = full_exists.to_sql
need('exists-both', exists_sql.include?('kiln_full') && exists_sql.include?('u__id') && exists_sql.include?('g__id'))
need('exists-outside',
     exists_sql.include?('UNION ALL') && !exists_sql.index('EXISTS').nil? && exists_sql.index('UNION ALL') < exists_sql.index('EXISTS'))

begin
  SqlUser.col('id;drop')
  print "bad-ident-miss\n"
rescue ArgumentError
  print "bad-ident\n"
end

begin
  SqlUser.all.inner_join(SqlPost, on: 'posts.user_id = users.id')
  print "bad-on-miss\n"
rescue ArgumentError
  print "bad-on\n"
end

begin
  SqlUser.import([], { on_duplicate_key_ignore: true, on_duplicate_key_update: true })
  print "bad-both-miss\n"
rescue ArgumentError
  print "bad-both\n"
end

begin
  SqlUser.import([{ 'name' => 'a' }], { returning: true })
  print "bad-return-miss\n"
rescue Kiln::DB::UnsupportedReturn
  print "bad-return\n"
end

ignore_part = Kiln::DB::ImportPart.new('id,name', %w[id name], [[1, 'a']], [0])
ignore_sql = Kiln::DB::Import.insert_sql(SqlUser, ignore_part, Kiln::DB::ImportMode.new(true, false, false), false)[0]
need('mysql-ignore', ignore_sql == 'INSERT IGNORE INTO `users` (`id`, `name`) VALUES (?, ?)')
print "mysql-ignore\n"

empty = SqlUser.import([])
print 'empty '
print empty.state
print ' '
print empty.length
print "\n"
src = Kiln::DB::Generate.models(:postgres, [{ name: 'users', columns: %w[id name], primary_key: ['id'] }])
print src
need('gen', src.include?('class Users < Kiln::DB::Model') && src.include?("define_table(:postgres, 'users'"))
print "ok query-sql\n"
