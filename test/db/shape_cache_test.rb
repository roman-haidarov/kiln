require 'kiln/db'

Thread.current

def need(label, cond)
  return if cond

  print 'FAIL '
  print label
  print "\n"
  raise label
end

class ShapeUser < Kiln::DB::Model
end
ShapeUser.define_table(:postgres, 'users', %w[id name age active], ['id'], 'u')

class ShapePost < Kiln::DB::Model
end
ShapePost.define_table(:postgres, 'posts', %w[id user_id title score], ['id'], 'p')
ShapeUser.has_many(:posts, ShapePost, 'user_id')

class ShapeMy < Kiln::DB::Model
end
ShapeMy.define_table(:mysql, 'users', %w[id name age active], ['id'], 'u')

def same_list?(left, right)
  return false unless left.length == right.length

  i = 0
  while i < left.length
    return false unless left[i] == right[i]

    i += 1
  end
  true
end

def check(label, rel, mode = :rows)
  binds = []
  direct = Kiln::DB::Sql.piece(rel.model.dialect, rel, mode, binds)
  first = rel.compile(mode)
  second = rel.compile(mode)
  need("#{label} miss sql", first[0] == direct)
  need("#{label} hit sql", second[0] == direct)
  need("#{label} miss binds", same_list?(first[1], binds))
  need("#{label} hit binds", same_list?(second[1], binds))
  print 'ok '
  print label
  print ' binds '
  print binds.length
  print "\n"
end

u = ShapeUser.table
p = ShapePost.table
m = ShapeMy.table

ids = [1, 2, 3]
ids.each do |id|
  check("eq #{id}", ShapeUser.where(id: id))
  check("pick shape #{id}", ShapeUser.where(id: id).order(u[:id].asc).limit(1).select(u[:name]))
end
check('eq string', ShapeUser.where(name: 'Ann'))
check('eq other string', ShapeUser.where(name: 'Bob'))
check('null', ShapeUser.where(name: nil))
check('not null', ShapeUser.where(u[:name].not_eq(nil)))
check('in 2', ShapeUser.where(id: [1, 2]))
check('in 3', ShapeUser.where(id: [1, 2, 3]))
check('in empty', ShapeUser.where(id: []))
check('not in', ShapeUser.where(u[:id].not_in([4, 5])))
check('in with nil', ShapeUser.where(name: [nil, 'Ann']))
check('range', ShapeUser.where(age: 18..40))
check('range exclusive', ShapeUser.where(age: 18...40))
check('and or', ShapeUser.where(u[:name].eq('Ann').and(u[:active].eq(true)).or(u[:age].gt(18).and(u[:age].lteq(40)))))
check('not', ShapeUser.where(u[:age].gt(3).not))
check('col to col', ShapeUser.where(u[:age].eq(u[:id])))
check('bound left', ShapeUser.where(Kiln::DB::Bound.new(5).lt(u[:age])))
check('two wheres', ShapeUser.where(active: true).where(u[:age].gteq(21)))
check('order desc', ShapeUser.where(active: true).order(u[:age].desc, u[:id].asc))
check('limit 5', ShapeUser.all.order(u[:id].asc).limit(5))
check('limit 6', ShapeUser.all.order(u[:id].asc).limit(6))
check('offset', ShapeUser.all.order(u[:id].asc).limit(10).offset(20))
check('offset other', ShapeUser.all.order(u[:id].asc).limit(10).offset(30))
check('distinct', ShapeUser.select(u[:name]).distinct)
check('alias', ShapeUser.select(u[:name].as(:n), u[:id]))
check('all cols', ShapeUser.all)
check('count', ShapeUser.where(active: true), :count)
check('count limited', ShapeUser.where(active: true).order(u[:id].asc).limit(3), :count)
check('exists', ShapeUser.where(id: 7), :exists)
check('root', ShapeUser.where(active: false), :root)
check('mysql eq', ShapeMy.where(id: 1))
check('mysql pick', ShapeMy.where(id: 2).order(m[:id].asc).limit(1).select(m[:name]))
check('mysql offset only', ShapeMy.all.order(m[:id].asc).offset(4))
check('like', ShapeUser.where(u[:name].matches('A%')))
check('function', ShapeUser.select(u[:name].lower.as(:low)))
check('join', ShapeUser.joins(u.join(p).on(p[:user_id].eq(u[:id]).and(p[:score].gt(5))).join_sources))
check('group', ShapeUser.select(u[:active], u[:id].count.as(:n)).group(u[:active]))
check('subquery', ShapeUser.where(u[:id].in(p.project(p[:user_id]).where(p[:score].gteq(10)))))
check('table source', u.where(u[:id].eq(9)))

before = Kiln::DB::Sql::Shape.size
ShapeUser.where(id: 99).compile(:rows)
need('hit adds no entry', Kiln::DB::Sql::Shape.size == before)
need('cache bounded', before <= Kiln::DB::Sql::Shape::CAPACITY)
print 'ok cache size stable '
print before.positive?
print "\n"

size = Kiln::DB::Sql::Shape.size
ShapeUser.all.order(u[:id].asc).limit(10).offset(40).compile(:rows)
ShapeUser.all.order(u[:id].asc).limit(10).offset(50).compile(:rows)
need('offset pages not cached', Kiln::DB::Sql::Shape.size == size)
wide = []
n = 0
while n < 40
  wide << n
  n += 1
end
check('in 40', ShapeUser.where(id: wide))
need('long in list not cached', Kiln::DB::Sql::Shape.size == size)
check('in 32', ShapeUser.where(id: wide.first(32)))
need('in 32 cached', Kiln::DB::Sql::Shape.size == size + 1)
print "ok pagination and long lists bypass the cache\n"

text = ShapeUser.where(id: 1).to_sql
need('returned sql is mutable', !text.frozen?)
text << ' FOR UPDATE'
need('cache untouched by caller', ShapeUser.where(id: 2).to_sql == ShapeUser.where(id: 3).to_sql)
need('cache text clean', !ShapeUser.where(id: 4).to_sql.include?('FOR UPDATE'))
print "ok returned sql is a private copy\n"

sub = ShapeUser.select(u[:id].count).as('totals')
check('subquery unaliased count', ShapeUser.from(sub).select(sub[:*]))
math = ShapeUser.select(u[:age] + 1).as('calc')
check('subquery arithmetic', ShapeUser.from(math).select(math[:*]))
print "ok unaliased subquery projections\n"

leak = ShapeUser.all
leak.orders << u[:age].desc
need('fresh all after mutation', ShapeUser.all.orders.empty?)
need('fresh all is new', !ShapeUser.all.equal?(ShapeUser.all))
need('fresh table is new', !ShapeUser.table.equal?(ShapeUser.table))
print "ok model.all and model.table stay independent\n"

class ShapeMut < Kiln::DB::Model
end
ShapeMut.define_table(:postgres, 'people', %w[id name], ['id'], 'pp')
check('columns before', ShapeMut.all)
check('columns before again', ShapeMut.all)
ShapeMut.columns << 'email'
check('columns after', ShapeMut.all)
need('new column in sql', ShapeMut.all.to_sql.include?('"pp"."email"'))
need('new column usable', ShapeMut.table[:email].name == 'email')
check('new column where', ShapeMut.where(email: 'a@b'))
print "ok live column metadata\n"

base = ShapeUser.where(active: true)
base_sql = base.to_sql
left = base.where(u[:age].gt(30))
right = base.order(u[:name].asc).limit(2)
grouped = base.select(u[:age], u[:id].count.as(:n)).group(u[:age])
joined = base.joins(u.join(p).on(p[:user_id].eq(u[:id])).join_sources)
check('branch left', left)
check('branch right', right)
check('branch group', grouped)
check('branch join', joined)
need('base unchanged', base.to_sql == base_sql)
print "ok branching after to_sql\n"

samples = ['', '_', 'a', 'A_Z9', 'a1', '1a', '9', 'a-b', 'a b', "a\n", "\na", 'é', 'aé', 'user_id', '__x', 'x.y', '$1', 'Ж']
samples.each do |name|
  need("ident #{name.inspect}", Kiln::DB::Ident.ok?(name) == Kiln::DB::Ident::NAME.match?(name))
end
need('ident non string', !Kiln::DB::Ident.ok?(:name) && !Kiln::DB::Ident.ok?(nil))
print "ok identifier check matches the pattern\n"

def hammer(seed)
  u = ShapeUser.table
  bad = 0
  i = 0
  while i < 2000
    id = seed * 10_000 + i
    rel = i.even? ? ShapeUser.where(id: id).order(u[:id].asc).limit(1).select(u[:name]) : ShapeUser.where(u[:age].gteq(id).and(u[:name].eq('x')))
    binds = []
    direct = Kiln::DB::Sql.piece(:postgres, rel, :rows, binds)
    got = rel.compile(:rows)
    bad += 1 unless got[0] == direct && same_list?(got[1], binds)
    i += 1
  end
  bad
end

threads = []
t = 0
while t < 4
  seed = t
  threads << Thread.new { hammer(seed) }
  t += 1
end
failures = 0
threads.each { |th| failures += th.value }
need('threads agree', failures.zero?)
print "ok 8000 concurrent compiles\n"
