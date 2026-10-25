require 'kiln/db'

def check(label, passed)
  raise label unless passed

  puts "ok   #{label}"
end

class ArchitectureUser < Kiln::DB::Model
end

ArchitectureUser.define_table(:postgres, 'users', %w[id name], ['id'], 'u')
rows = [{ 'id' => 1, 'name' => 'a' }, { 'id' => 2, 'name' => 'b' }, { 'id' => 3 }, { 'id' => 4, 'name' => nil }]
entries = rows.each_with_index.map { |row, index| [row, index] }
parts = Kiln::DB::Import.group_rows(ArchitectureUser, entries, false)
check('import preserves contiguous column groups', parts.length == 3)
check('import retains original input indexes', parts[0].originals == [0, 1] && parts[2].originals == [3])
check('import distinguishes missing fields from NULL', parts[1].columns == ['id'] && parts[2].rows == [[4, nil]])
page = Kiln::DB::Import.page_part(parts[0], 1, 100)
check('import page clamps its upper bound', page.columns == %w[id name] && page.rows == [[2, 'b']])
mode = Kiln::DB::ImportMode.new(false, false, false)
sql, binds = Kiln::DB::Import.insert_sql(ArchitectureUser, page, mode, false)
check('import keeps SQL and bind ordering', sql == 'INSERT INTO "users" ("id", "name") VALUES ($1, $2)' && binds == [2, 'b'])
check('import never changes source rows', rows[0] == { 'id' => 1, 'name' => 'a' } && rows[2] == { 'id' => 3 })

id = ArchitectureUser.col('id')
name = ArchitectureUser.col('name')
relation = ArchitectureUser.all.where(id.eq(7).and(name.eq('x').or(id.gt(9))))
sql, binds = relation.compile(:rows)
check('predicate context preserves left-to-right binds', binds == [7, 'x', 9])
check('predicate context numbers each placeholder', sql.include?('$1') && sql.include?('$2') && sql.include?('$3'))

check('database error classification preserves constraints',
      Kiln::DB::Conn.error_class(Kiln::DB::Native::UNIQUE) == Kiln::DB::UniqueViolation &&
      Kiln::DB::Conn.error_class(Kiln::DB::Native::DEADLOCK) == Kiln::DB::Deadlock)
check('database error classification preserves fallback', Kiln::DB::Conn.error_class(-999) == Kiln::DB::Error)
