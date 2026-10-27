require 'kiln/db'

Thread.current

def need(label, cond)
  raise label unless cond

  print 'ok '
  print label
  print "\n"
end

class NilUser < Kiln::DB::Model
end
NilUser.define_table(:postgres, 'users', %w[id name age], ['id'], 'u')
u = NilUser.table

need('not_eq nil through table', NilUser.where(u[:name].not_eq(nil)).to_sql.end_with?('"u"."name" IS NOT NULL'))
need('eq nil through table', NilUser.where(u[:name].eq(nil)).to_sql.end_with?('"u"."name" IS NULL'))
need('not_eq integer', NilUser.where(Kiln::DB::Col.new('u', 'age').not_eq(40)).to_binds == [40])
need('eq integer', NilUser.where(Kiln::DB::Col.new('u', 'age').eq(5)).to_binds == [5])
