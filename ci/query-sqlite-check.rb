require 'fiddle/import'
module Kernel
  def ffi_func(*) = nil
  def ffi_lib(*) = nil
end
require 'kiln/db'
module SQLiteCheck
  extend Fiddle::Importer
  dlload RUBY_PLATFORM.include?('darwin') ? 'libsqlite3.dylib' : 'libsqlite3.so.0'
  extern 'int sqlite3_open(const char*, void*)'
  extern 'int sqlite3_prepare_v2(void*, const char*, int, void*, void*)'
  extern 'int sqlite3_bind_null(void*, int)'
  extern 'int sqlite3_bind_int64(void*, int, long long)'
  extern 'int sqlite3_bind_double(void*, int, double)'
  extern 'int sqlite3_bind_text(void*, int, const char*, int, void*)'
  extern 'int sqlite3_step(void*)'
  extern 'int sqlite3_column_count(void*)'
  extern 'int sqlite3_column_type(void*, int)'
  extern 'long long sqlite3_column_int64(void*, int)'
  extern 'double sqlite3_column_double(void*, int)'
  extern 'char* sqlite3_column_text(void*, int)'
  extern 'char* sqlite3_errmsg(void*)'
  extern 'int sqlite3_finalize(void*)'
  extern 'int sqlite3_close(void*)'
  class << self
    def pointer_box = Fiddle::Pointer.malloc(Fiddle::SIZEOF_VOIDP, Fiddle::RUBY_FREE)
    def unbox(box) = Fiddle::Pointer.new(box[0, Fiddle::SIZEOF_VOIDP].unpack1('J'))
    def execute(db, sql, binds = [])
      box = pointer_box
      rc = sqlite3_prepare_v2(db, sql, -1, box, nil)
      raise "prepare #{rc}: #{sqlite3_errmsg(db).to_s}: #{sql}" unless rc.zero?
      stmt = unbox(box)
      begin
        binds.each_with_index do |value, i|
          at = i + 1
          rc = case value
               when nil then sqlite3_bind_null(stmt, at)
               when Integer then sqlite3_bind_int64(stmt, at, value)
               when Float then sqlite3_bind_double(stmt, at, value)
               when true, false then sqlite3_bind_int64(stmt, at, value ? 1 : 0)
               else sqlite3_bind_text(stmt, at, value, value.bytesize, -1)
               end
          raise "bind #{rc}" unless rc.zero?
        end
        rows = []
        while (rc = sqlite3_step(stmt)) == 100
          rows << Array.new(sqlite3_column_count(stmt)) do |i|
            case sqlite3_column_type(stmt, i)
            when 1 then sqlite3_column_int64(stmt, i)
            when 2 then sqlite3_column_double(stmt, i)
            when 3 then sqlite3_column_text(stmt, i).to_s
            when 5 then nil
            else raise 'unsupported SQLite result type'
            end
          end
        end
        raise "step #{rc}: #{sqlite3_errmsg(db).to_s}" unless rc == 101
        rows
      ensure
        sqlite3_finalize(stmt)
      end
    end
  end
end
class EUser < Kiln::DB::Model; end
class EPost < Kiln::DB::Model; end
class ETag < Kiln::DB::Model; end
EUser.define_table(:postgres, 'users', %w[id name male age manager_id], ['id'], 'u')
EPost.define_table(:postgres, 'posts', %w[id user_id title score], ['id'], 'p')
ETag.define_table(:postgres, 'tags', %w[id post_id name], ['id'], 't')
box = SQLiteCheck.pointer_box
raise 'open' unless SQLiteCheck.sqlite3_open(':memory:', box).zero?
db = SQLiteCheck.unbox(box)
begin
  ['CREATE TABLE users(id INTEGER PRIMARY KEY,name TEXT,male INTEGER,age INTEGER,manager_id INTEGER)',
   'CREATE TABLE posts(id INTEGER PRIMARY KEY,user_id INTEGER,title TEXT,score INTEGER)',
   'CREATE TABLE tags(id INTEGER PRIMARY KEY,post_id INTEGER,name TEXT)'].each { |sql| SQLiteCheck.execute(db, sql) }
  [[1,'Criss',1,17,nil],[2,'Ada',0,30,1],[3,'Bob',1,45,1],[4,'Carol',1,40,nil]].each { |row| SQLiteCheck.execute(db,'INSERT INTO users VALUES(?,?,?,?,?)',row) }
  [[10,1,'a',2],[11,2,'b',8],[12,2,'c',12],[13,4,'d',20]].each { |row| SQLiteCheck.execute(db,'INSERT INTO posts VALUES(?,?,?,?)',row) }
  [[1,10,'featured'],[4,12,'normal'],[8,99,'featured']].each { |row| SQLiteCheck.execute(db,'INSERT INTO tags VALUES(?,?,?)',row) }
  check = ->(label, query, expected) do
    sql, binds = query.compile
    got = SQLiteCheck.execute(db,sql,binds)
    raise "#{label}: #{got.inspect} != #{expected.inspect}" unless got == expected
    raise "#{label}: mutation" unless query.compile == [sql,binds]
    puts "ok #{label}"
  end
  u=EUser.table; p=EPost.table; t=ETag.table
  pred=u[:name].eq('Criss').and(u[:male].eq(true)).or(u[:age].gt(18).and(u[:age].lteq(40)))
  check.call('requested predicate semantics',EUser.where(pred).select(u[:id]).order(u[:id]),[[1],[2],[4]])
  check.call('NULL and hash semantics',EUser.where(manager_id:[nil,1]).select(u[:id]).order(u[:id]),[[1],[2],[3],[4]])
  check.call('exclusive range',EUser.where(age:18...40).select(u[:id]),[[2]])
  check.call('IN subquery',EUser.where(u[:id].in(p.project(p[:user_id]).where(p[:score].gteq(10)))).select(u[:id]).order(u[:id]),[[2],[4]])
  check.call('correlated EXISTS',EUser.where(p.where(p[:user_id].eq(u[:id]).and(p[:score].gt(15))).exists).select(u[:id]),[[4]])
  check.call('scalar aggregate',EUser.where(u[:age].gt(p.project(p[:score].sum))).select(u[:id]),[[3]])
  q=u.join(p).on(p[:user_id].eq(u[:id]).and(p[:score].gt(5))).join(t,Kiln::DB::Arel::Nodes::OuterJoin).on(t[:post_id].eq(p[:id]).and(t[:name].eq('featured'))).project(u[:name],p[:id],t[:name]).order(p[:id])
  check.call('complex ON and outer join',q,[['Ada',11,nil],['Ada',12,nil],['Carol',13,nil]])
  boss=u.alias(:boss)
  check.call('self alias',u.join(boss).on(u[:manager_id].eq(boss[:id])).project(u[:name],boss[:name].as(:manager)).order(u[:id]),[['Ada','Criss'],['Bob','Criss']])
  check.call('GROUP HAVING',p.project(p[:user_id],p[:score].sum.as(:total)).group(p[:user_id]).having(p[:score].sum.gt(10)).order(p[:user_id]),[[2,20],[4,20]])
  scores=p.project(p[:user_id],p[:score].sum.as(:total)).group(p[:user_id]).as(:scores)
  check.call('derived join',u.join(scores).on(scores[:user_id].eq(u[:id])).project(u[:id],scores[:total]).where(scores[:total].gteq(20)).order(u[:id]),[[2,20],[4,20]])
  check.call('CTE',scores.project(scores[:user_id],scores[:total]).with(scores).where(scores[:total].gteq(20)).order(scores[:user_id]),[[2,20],[4,20]])
  case_node=Kiln::DB::Arel::Nodes::Case.new.when(u[:age].gteq(18)).then('adult').else('child')
  check.call('CASE',u.project(case_node.as(:kind)).order(u[:id]),[['child'],['adult'],['adult'],['adult']])
  window=Kiln::DB::Arel::Nodes::Window.new.partition(p[:user_id]).order(p[:score].desc)
  rank=Kiln::DB::Arel::Nodes::NamedFunction.new('ROW_NUMBER',[]).over(window).as(:position)
  check.call('window',p.project(p[:id],rank).order(p[:id]),[[10,1],[11,2],[12,1],[13,1]])
  check.call('bound arithmetic',u.project((u[:age]+2).as(:next_age)).where(u[:id].eq(1)),[[19]])
  check.call('injection remains data',EUser.where(u[:name].eq("' OR 1=1 --")).select(u[:id]),[])
  EUser.define_table(:mysql,'users',%w[id name male age manager_id],['id'],'u')
  ETag.define_table(:mysql,'tags',%w[id post_id name],['id'],'t')
  u=EUser.table; t=ETag.table
  q=EUser.all.full_join(ETag,on:u[:id].eq(t[:id])).select(u[:age].sum.as(:total)).where(t[:name].eq('featured').or(u[:id].eq(2)))
  check.call('MySQL FULL JOIN rewrite with expressions',q,[[47]])
  puts '16/16 SQL semantic checks passed on SQLite; PostgreSQL/MySQL native integration is separate'
ensure
  SQLiteCheck.sqlite3_close(db)
end
