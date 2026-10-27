require 'kiln/db'

Thread.current

def need(label, cond)
  raise label unless cond
end

def same_compile(rel, mode = :rows)
  binds = []
  direct = Kiln::DB::Sql.piece(rel.model.dialect, rel, mode, binds)
  2.times do
    got = rel.compile(mode)
    need('sql differs', got[0] == direct)
    need('binds differ', got[1] == binds)
  end
end

def rejects(rel)
  direct_error = false
  cached_error = false
  begin
    Kiln::DB::Sql.piece(rel.model.dialect, rel, :rows, [])
  rescue ArgumentError
    direct_error = true
  end
  begin
    rel.compile
  rescue ArgumentError
    cached_error = true
  end
  need('direct rejects invalid identifier', direct_error)
  need('cache must reject invalid identifier', cached_error)
end

class CacheUser < Kiln::DB::Model
end
class CacheMy < Kiln::DB::Model
end
CacheUser.define_table(:postgres, String.new('users'), [String.new('id'), String.new('name'), String.new('age')],
                       [String.new('id')], String.new('u'))
CacheMy.define_table(:mysql, 'users', %w[id name age], ['id'], 'u')

u = CacheUser.table
CacheUser.select(u[:id], u[:name]).to_sql
column = Kiln::DB::Col.new('u', String.new('id'))
query = CacheUser.select(column)
column.name.replace('id,u.name')
rejects(query)
print "ok projection delimiter collision rejected\n"

CacheUser.all.to_sql
CacheUser.columns.replace([String.new('id,name,age')])
rejects(CacheUser.all)
CacheUser.columns.replace([String.new('id'), String.new('name'), String.new('age')])
print "ok metadata delimiter collision rejected\n"

['x.y', 'x,y', 'x|S', 'x>y', 'x:y', '(x)', "x\0y", 'Ж'].each do |invalid|
  col = Kiln::DB::Col.new('u', String.new('name'))
  rel = CacheUser.where(col.eq(5)).select(u[:name])
  same_compile(rel)
  col.name.replace(invalid)
  rejects(rel)
end
print "ok mutated identifiers follow renderer validation\n"

alias_name = String.new('u')
table = Kiln::DB::Table.new(CacheUser, alias_name)
alias_name.replace('bad-alias')
alias_error = false
begin
  table[:id]
rescue ArgumentError
  alias_error = true
end
need('table must recheck a mutable alias', alias_error)
print "ok mutable table aliases are revalidated\n"

my = CacheMy.where(id: 4)
same_compile(my)
bad_dialect = false
begin
  Kiln::DB::Sql.emit(:invalid, my, :rows)
rescue ArgumentError
  bad_dialect = true
end
need('invalid dialect cannot hit mysql cache', bad_dialect)
print "ok dialect validation on a warm cache\n"

rel = CacheUser.where(id: 8)
same_compile(rel)
CacheUser.table_name.replace('other_users')
CacheUser.table_alias.replace('other_u')
CacheUser.columns << 'email'
same_compile(rel)
same_compile(CacheUser.where(email: 'a@b'))
CacheUser.primary_key.replace(['name'])
same_compile(rel, :root)
need('new root identity', rel.compile(:root)[0].include?('"other_u"."name"'))
CacheUser.define_table(:postgres, 'users', %w[id name age], ['id'], 'u')
print "ok table alias columns and root identity follow metadata\n"

[CacheUser, CacheMy].each do |model|
  table = model.table
  [nil, 3, 'three', true, [], [nil], [3, nil], [3, 4], table[:age]].each do |value|
    same_compile(model.where(id: value))
  end
  %i[rows count exists exists_sub root].each do |mode|
    same_compile(model.where(table[:age].gteq(18).and(table[:name].not_eq(nil))).limit(3), mode)
  end
end
print "ok changing bound types and compile modes\n"

rel = CacheUser.where(id: 9)
rel.compile
sql, binds = rel.compile
sql.replace('broken')
binds << 123
same_compile(rel)
need('fresh bind array', rel.compile[1] == [9])
print "ok returned sql and bind arrays stay independent\n"

class OpaqueBind
  def ==(other)
    raise 'cache must not compare bound values'
  end

  def equal?(other)
    raise 'cache must not call bound value identity methods'
  end
end
Kiln::DB::Sql::Shape.clear
opaque = OpaqueBind.new
opaque_rel = CacheUser.where(id: opaque)
first = opaque_rel.compile
second = opaque_rel.compile
need('opaque sql stable', first[0] == second[0])
need('opaque bind untouched', first[1][0].is_a?(OpaqueBind) && second[1][0].is_a?(OpaqueBind))
need('opaque query cached', Kiln::DB::Sql::Shape.size == 1)
print "ok cache never calls equality on bound values\n"

u = CacheUser.table
same_compile(CacheUser.where(u[:id].eq(7).and(u[:name].matches('a%'))))
print "ok partial key walks do not duplicate fallback binds\n"

Kiln::DB::Sql::Shape.clear
key = String.new('key')
sql = String.new('SELECT 1')
Kiln::DB::Sql::Shape.store(key, sql)
key.replace('changed')
sql.replace('changed')
need('private key and sql', Kiln::DB::Sql::Shape.fetch('key') == 'SELECT 1')
need('cached text frozen', Kiln::DB::Sql::Shape.fetch('key').frozen?)
Kiln::DB::Sql::Shape.store('too_large', 'x' * Kiln::DB::Sql::Shape::MAX_ENTRY_BYTES)
need('oversized entry not retained', Kiln::DB::Sql::Shape.fetch('too_large').nil?)
print "ok cache owns its keys and values and bounds entry bytes\n"

Kiln::DB::Sql::Shape.clear
wide = Kiln::DB::Col.new('u', 'x' * Kiln::DB::Sql::Shape::MAX_KEY_BYTES)
same_compile(CacheUser.select(wide))
need('oversized shape not retained', Kiln::DB::Sql::Shape.size.zero?)
print "ok oversized queries compile without retention\n"

capacity = Kiln::DB::Sql::Shape::CAPACITY
i = 0
while i < capacity + 32
  same_compile(CacheUser.where(id: i).limit(i))
  need('entry bound', Kiln::DB::Sql::Shape.size <= capacity)
  i += 1
end
recent = CacheUser.where(id: 1).limit(capacity + 31)
recent_key = Kiln::DB::Sql::Shape.key(:postgres, recent, :rows, [])
need('new shapes retained after capacity', !Kiln::DB::Sql::Shape.fetch(recent_key).nil?)
old_key = Kiln::DB::Sql::Shape.key(:postgres, CacheUser.where(id: 1).limit(0), :rows, [])
need('old generation evicted', Kiln::DB::Sql::Shape.fetch(old_key).nil?)
print "ok cache admits new shapes and evicts old generations\n"

Kiln::DB::Sql::Shape.clear
half = capacity / 2
i = 0
while i <= half
  CacheUser.limit(i).compile
  i += 1
end
hot = CacheUser.limit(0)
hot_key = Kiln::DB::Sql::Shape.key(:postgres, hot, :rows, [])
need('promote older hit', !Kiln::DB::Sql::Shape.fetch(hot_key).nil?)
i = half + 1
while i < capacity
  CacheUser.limit(i).compile
  i += 1
end
need('hot survives rotation', !Kiln::DB::Sql::Shape.fetch(hot_key).nil?)
need('promotion respects bound', Kiln::DB::Sql::Shape.size <= capacity)
print "ok older cache hits are promoted\n"

def churn(worker)
  i = 0
  while i < 2500
    rel = CacheUser.where(id: worker * 10_000 + i).limit(worker * 10_000 + i)
    same_compile(rel)
    Kiln::DB::Sql::Shape.clear if worker.zero? && i % 137 == 0
    need('concurrent bound', Kiln::DB::Sql::Shape.size <= Kiln::DB::Sql::Shape::CAPACITY)
    i += 1
  end
  true
end

jobs = []
4.times { |worker| jobs << Thread.new { churn(worker) } }
jobs.each { |job| need('worker completed', job.value) }
print "ok 20000 concurrent compiles with eviction and clear\n"
