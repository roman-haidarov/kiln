require 'kiln/db'

def need(label, condition)
  raise label unless condition

  puts "ok #{label}"
end

def rejects(label)
  raised = false
  begin
    yield
  rescue ArgumentError
    raised = true
  end
  need(label, raised)
end

class ArelUser < Kiln::DB::Model; end
class ArelPost < Kiln::DB::Model; end
class ArelTag < Kiln::DB::Model; end

ArelUser.define_table(:postgres, 'users', %w[id name male age manager_id], ['id'], 'u')
ArelPost.define_table(:postgres, 'posts', %w[id user_id title score], ['id'], 'p')
ArelTag.define_table(:postgres, 'tags', %w[id post_id name], ['id'], 't')
u = ArelUser.table
p = ArelPost.table
t = ArelTag.table

query = ArelUser.where(u[:name].eq('Criss').and(u[:male].eq(true)).or(u[:age].gt(18).and(u[:age].lteq(40))))
sql, binds = query.compile
need('requested syntax and precedence',
     sql.end_with?('WHERE (("u"."name" = $1 AND "u"."male" = $2) OR ("u"."age" > $3 AND "u"."age" <= $4))') &&
     binds == ['Criss', true, 18, 40])
need('arel_table alias', ArelUser.arel_table[:id].scope == 'u')
manager = Kiln::DB::Arel::SelectManager.new(u).project(u[:id]).where(u[:age].gteq(18))
need('SelectManager entry point', manager.to_binds == [18] && manager.to_sql.start_with?('SELECT "u"."id"'))
need('symbol projections', ArelUser.select(:id, :name).to_sql.start_with?('SELECT "u"."id", "u"."name"'))
need('hash filters', ArelUser.where(name: 'Criss', male: true).to_binds == ['Criss', true])
need('hash range', ArelUser.where(age: 18...40).to_binds == [18, 40])
need('hash array with NULL', ArelUser.where(name: [nil, 'Criss']).to_sql.end_with?('("u"."name" IN ($1) OR "u"."name" IS NULL)'))
need('null equality', ArelUser.where(u[:name].eq(nil)).to_sql.end_with?('"u"."name" IS NULL'))
need('null inequality', ArelUser.where(u[:name].not_eq(nil)).to_sql.end_with?('"u"."name" IS NOT NULL'))
need('comparison aliases', ArelUser.where(u[:age].gteq(18).and(u[:age].not_eq(40))).to_binds == [18, 40])
need('inclusive between', ArelUser.where(u[:age].between(18..40)).to_sql.end_with?('"u"."age" BETWEEN $1 AND $2'))
need('endless range', ArelUser.where(u[:age].between(18..)).to_sql.end_with?('"u"."age" >= $1'))
need('beginless range', ArelUser.where(u[:age].between(..40)).to_sql.end_with?('"u"."age" <= $1'))
need('negated range', ArelUser.where(u[:age].not_between(18...40)).to_sql.include?('(NOT ('))
need('empty IN', ArelUser.where(u[:id].in([])).to_sql.end_with?('WHERE FALSE'))
need('empty NOT IN', ArelUser.where(u[:id].not_in([])).to_sql.end_with?('WHERE TRUE'))

base = u.project(u[:id])
joined = base.join(p).on(p[:user_id].eq(u[:id]).and(p[:score].gt(5)))
joined = joined.join(t, Kiln::DB::Arel::Nodes::OuterJoin).on(t[:post_id].eq(p[:id]).or(t[:name].eq('featured')))
sql, binds = joined.where(u[:age].gteq(18)).compile
need('complex join and bind order', sql.include?('LEFT JOIN "tags" "t" ON (') && binds == [5, 'featured', 18])
need('join_sources composition', ArelUser.joins(joined.join_sources).to_binds == [5, 'featured'])
on_node = Kiln::DB::Arel::Nodes::On.new(p[:user_id].eq(u[:id]))
join_node = Kiln::DB::Arel::Nodes::OuterJoin.new(p, on_node)
need('standalone Arel join node', ArelUser.joins(join_node).to_sql.include?('LEFT JOIN "posts" "p" ON "p"."user_id" = "u"."id"'))
need('joins leave source unchanged', base.join_sources.empty? && base.to_binds.empty?)
boss = u.alias(:boss)
self_join = u.project(u[:name], boss[:name].as(:manager)).join(boss).on(u[:manager_id].eq(boss[:id]))
need('self join aliases', self_join.to_sql.include?('INNER JOIN "users" "boss" ON "u"."manager_id" = "boss"."id"'))
need('alias projection names', self_join.pick_names == %w[name manager])
need('aliased hash scope', boss.where(name: 'Ada').to_sql.end_with?('"boss"."name" = $1'))

ids = p.project(p[:user_id]).where(p[:score].gteq(10))
need('IN subquery', ArelUser.where(u[:id].in(ids)).to_binds == [10])
need('correlated EXISTS', ArelUser.where(p.where(p[:user_id].eq(u[:id])).exists).to_sql.include?('EXISTS (SELECT 1'))
need('scalar subquery', ArelUser.where(u[:age].gt(p.project(p[:score].average))).to_sql.include?('> (SELECT AVG('))
recent = p.project(p[:user_id], p[:score].sum.as(:total)).where(p[:score].gt(1)).group(p[:user_id]).as(:recent)
derived = u.project(u[:name], recent[:total]).join(recent).on(recent[:user_id].eq(u[:id]))
need('derived join', derived.to_sql.include?('INNER JOIN (SELECT') && derived.to_binds == [1])
common = recent.project(recent[:user_id], recent[:total]).with(recent).where(recent[:total].gt(10))
need('common table', common.to_sql.start_with?('WITH "recent" AS (SELECT') && common.to_sql.include?('FROM "recent" "recent"'))
need('common table bind ordering', common.to_binds == [1, 10])
common_node = Kiln::DB::Arel::Nodes::As.new(recent, recent.query)
need('Arel WITH node', recent.project(recent[:total]).with(common_node).to_binds == [1])

score = (p[:score] + 2) * 3
aggregate = p.project(p[:user_id], score.sum.as(:total)).group(p[:user_id]).having(p[:score].sum.gt(10)).order(score.desc)
need('aggregate having and order binds', aggregate.to_binds == [2, 3, 10, 2, 3])
need('aggregate name', aggregate.to_sql.include?('SUM((("p"."score" + $1) * $2)) AS "total"'))
case_node = Kiln::DB::Arel::Nodes::Case.new.when(u[:age].gteq(18)).then('adult').else('child')
need('searched CASE', u.project(case_node.as(:kind)).to_binds == [18, 'adult', 'child'])
simple_case = Kiln::DB::Arel::Nodes::Case.new(u[:male]).when(true).then('yes').else('no')
need('simple CASE', u.project(simple_case.as(:kind)).to_binds == [true, 'yes', 'no'])
window = Kiln::DB::Arel::Nodes::Window.new.partition(p[:user_id]).order(p[:score].desc)
rank = Kiln::DB::Arel::Nodes::NamedFunction.new('ROW_NUMBER', []).over(window).as(:position)
need('window expression', p.project(rank).to_sql.include?('ROW_NUMBER() OVER (PARTITION BY "p"."user_id" ORDER BY "p"."score" DESC)'))
need('quoted function values', u.project(u[:name].coalesce('unknown').as(:name)).to_binds == ['unknown'])
shifted = (u[:age] + 2).as(:shifted)
wrapped = ArelUser.select(shifted).distinct.order(shifted.asc).limit(2).compile(:count)
need('distinct count preserves ordered expression aliases', wrapped[0].include?('AS "shifted"') && wrapped[0].include?('ORDER BY "shifted" ASC') && wrapped[1] == [2])
need('wildcard count', u.project(Kiln::DB::Arel.star.count.as(:total)).to_sql.start_with?('SELECT COUNT(*) AS "total"'))
need('matches', ArelUser.where(u[:name].matches('c!_%', '!')).to_binds == ['c!_%', '!'])
need('case insensitive postgres match', ArelUser.where(u[:name].matches('c%')).to_sql.include?(' ILIKE '))
need('negated match', ArelUser.where(u[:name].does_not_match('c%')).to_sql.include?(' NOT ILIKE '))
union = u.project(u[:id]).where(u[:age].lt(18)).union(:all, u.project(u[:id]).where(u[:age].gt(40)))
need('union', union.to_sql.include?('UNION ALL') && union.to_binds == [18, 40])
need('union derived table', union.as(:ages).project(union.as(:ages)[:id]).to_binds == [18, 40])
need('take skip', base.order(u[:id]).take(10).skip(20).to_sql.end_with?('ORDER BY "u"."id" ASC LIMIT 10 OFFSET 20'))

injection = "' OR 1=1; DROP TABLE users; --"
safe = ArelUser.where(u[:name].eq(injection))
need('values never become SQL', !safe.to_sql.include?(injection) && safe.to_binds == [injection])
rejects('raw WHERE rejected') { ArelUser.where('id = 1') }
rejects('raw projection rejected') { u.project('COUNT(*)') }
rejects('invalid identifier rejected') { u[:'id;DROP'] }
rejects('invalid alias rejected') { u.alias('x;DROP') }
rejects('missing JOIN ON rejected') { u.join(p).to_sql }
rejects('wide IN subquery rejected') { ArelUser.where(u[:id].in(p.project(p[:id], p[:user_id]))).to_sql }
rejects('unsafe function rejected') { Kiln::DB::Arel::Nodes::NamedFunction.new('X);DROP', []) }

ArelUser.define_table(:mysql, 'users', %w[id name male age manager_id], ['id'], 'u')
ArelPost.define_table(:mysql, 'posts', %w[id user_id title score], ['id'], 'p')
ArelTag.define_table(:mysql, 'tags', %w[id post_id name], ['id'], 't')
mysql = ArelUser.table
my_query = ArelUser.where(mysql[:age].gteq(18).and(mysql[:name].matches('c%')))
need('mysql dialect', my_query.to_sql.include?('`u`.`age` >= ?') && my_query.to_sql.include?(' LIKE ?') && my_query.to_binds == [18, 'c%'])
full = ArelUser.all.full_join(ArelTag, on: ArelUser.table[:id].eq(ArelTag.table[:id]))
full = full.select(ArelUser.table[:age].sum.as(:total)).where(ArelTag.table[:name].eq('x'))
need('mysql full join expressions', full.to_sql.include?('SUM(`kiln_full`.`u__age`)') && full.to_sql.include?('UNION ALL') && full.to_binds == ['x'])
puts 'ok arel-builder'
