require 'kiln/db'

Thread.current

class Kiln::DB::Relation
  def run(mode)
    sql, binds = compile(mode)
    return [] if binds == [-1]

    [[sql, binds]]
  end

  def exposed_preloads = preload_list
end

def need(label, cond)
  raise label unless cond
end

def check_pick(rel, column)
  original = rel.compile
  expected = rel.orders.empty? ? rel.order(*rel.pk_orders) : rel
  expected = expected.limit(1).select(column)
  need('pick executes expected sql', rel.pick(column) == expected.to_sql)
  need('pick leaves receiver unchanged', rel.compile == original)
end

class PickUser < Kiln::DB::Model
end
class PickPost < Kiln::DB::Model
end
class PickNoKey < Kiln::DB::Model
end
PickUser.define_table(:postgres, 'users', %w[id name age], ['id'], 'u')
PickPost.define_table(:postgres, 'posts', %w[id user_id title], ['id'], 'p')
PickNoKey.define_table(:postgres, 'logs', ['name'], [], 'l')
PickUser.has_many(:posts, PickPost, 'user_id')

u = PickUser.table
base = PickUser.where(id: 3)
base.to_sql
check_pick(base, :name)
check_pick(base.limit(0).offset(4).select(:age), u[:name])
check_pick(base.order(u[:name].desc), :name)
check_pick(base.select(:age).distinct, u[:name])
print "ok pick executes the derived query and preserves receiver\n"

check_pick(PickUser.select(:age).group(:age).having(u[:age].gt(18)).order(u[:age]), u[:age])
sub = PickUser.select(:id, :name).as('sub')
check_pick(PickUser.from(sub).order(sub[:id]), sub[:name])
print "ok pick on groups and derived tables\n"

need('empty result', PickUser.where(id: -1).pick(:name).nil?)
blocked = false
begin
  PickNoKey.all.pick(:name)
rescue Kiln::DB::NonDeterministicQuery
  blocked = true
end
need('no identity and no order rejected', blocked)
check_pick(PickNoKey.order(:name), :name)
invalid = false
begin
  base.pick(:missing)
rescue ArgumentError
  invalid = true
end
need('invalid pick rejected', invalid)
print "ok empty unordered and invalid pick behavior\n"

preloaded = PickUser.all.preload(:posts)
child = preloaded.where(id: 3)
child.exposed_preloads.clear
need('derived preload list independent', preloaded.exposed_preloads.length == 1)
added = preloaded.preload(:posts)
need('adding preload independent', preloaded.exposed_preloads.length == 1 && added.exposed_preloads.length == 2)
check_pick(preloaded, :name)
print "ok preload list ownership across derivation\n"
