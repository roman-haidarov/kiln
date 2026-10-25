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

class ImportUser < Kiln::DB::Model
  def validate
    attrs['name'] == 'invalid' ? 'invalid name' : nil
  end
end

class ImportStamp < Kiln::DB::Model; end

class ImportConnection
  attr_reader :depth, :dialect, :statements, :commits, :rollbacks, :affected_rows
  attr_accessor :warnings

  def initialize(dialect)
    @dialect = dialect
    @depth = 0
    @statements = []
    @commits = 0
    @rollbacks = 0
    @affected_rows = 0
    @warnings = []
  end

  def claim! = nil
  def release_claim! = nil
  def pipelined? = false
  def mariadb? = false
  def warning_count = @warnings.length
  def transaction_open = @depth += 1

  def transaction_ok
    @depth -= 1
    @commits += 1
  end

  def transaction_fail
    @depth -= 1
    @rollbacks += 1
  end

  def exec(sql, binds)
    if sql.start_with?('INSERT')
      @statements << [sql, binds.dup]
      @affected_rows = sql.scan(/\), \(/).length + 1
      return []
    end
    return [['STRICT_TRANS_TABLES', '1', '1']] if sql.start_with?('SELECT @@session.sql_mode')
    return [['read committed']] if sql.start_with?("SELECT current_setting(")
    return @warnings if sql == 'SHOW WARNINGS'

    [[0]]
  end
end

ImportUser.define_table(:postgres, 'users', %w[id name age], ['id'], 'u')
pg = ImportConnection.new(:postgres)
Kiln::DB::Scope.use(pg)
rows = [{ id: 1, name: 'Ada', age: 30 }, { id: 2, name: 'Criss', age: 20 }]
result = ImportUser.import(rows, on_duplicate_key_update: [:name])
sql = pg.statements[-1][0]
need('update only requested columns', sql.end_with?('ON CONFLICT ("id") DO UPDATE SET "name" = EXCLUDED."name"'))
need('result counters', result.num_inserts == 1 && result.affected_rows == 2 && result.failed_instances.empty?)
need('input preserved', rows[0] == { id: 1, name: 'Ada', age: 30 })
need('legacy status extension', result.state == 'COMMITTED' && result.input_status(0) == 'applied_unknown')

ImportUser.import(rows, on_duplicate_key_update: { conflict_target: [:name], columns: [:age] })
need('custom conflict target', pg.statements[-1][0].end_with?('ON CONFLICT ("name") DO UPDATE SET "age" = EXCLUDED."age"'))
ImportUser.import(rows, on_duplicate_key_update: { constraint_name: :users_name_key, columns: [:age] })
need('named constraint', pg.statements[-1][0].include?('ON CONFLICT ON CONSTRAINT "users_name_key"'))
ImportUser.import(rows, on_duplicate_key_ignore: true)
need('ignore without update', pg.statements[-1][0].end_with?('ON CONFLICT DO NOTHING'))
ImportUser.import(rows, ignore: true)
need('AR ignore alias', pg.statements[-1][0].end_with?('ON CONFLICT DO NOTHING'))
ImportUser.import(rows, on_duplicate_key_update: :all)
need('all non-key columns', pg.statements[-1][0].end_with?('SET "name" = EXCLUDED."name", "age" = EXCLUDED."age"'))
ImportUser.import(rows, on_duplicate_key_update: true)
need('legacy true option', pg.statements[-1][0].include?('DO UPDATE SET'))
ImportUser.import(rows, on_duplicate_key_update: { columns: { name: :age } })
need('column mapping', pg.statements[-1][0].end_with?('SET "name" = EXCLUDED."age"'))

result = ImportUser.import(%i[id name], [[3, 'c'], [4, 'd']], batch_size: 1)
need('columns values input and batch_size', result.num_inserts == 2 && pg.statements[-1][1] == [4, 'd'])
model = ImportUser.new(id: 5, name: 'e', age: 50)
ImportUser.import(%i[id name], [model])
need('columns model input', pg.statements[-1][1] == [5, 'e'] && model.attrs['age'] == 50)
ImportUser.import(%i[id name], [{ id: 6, name: 'f', age: 60 }])
need('columns hash input', pg.statements[-1][1] == [6, 'f'])

bad = ImportUser.new(id: 7, name: 'invalid')
result = ImportUser.import([bad, { id: 8, name: 'h' }])
need('AR partial validation default', result.failed_instances.length == 1 && result.failed_instances[0].equal?(bad) && result.num_inserts == 1)
need('partial input statuses', result.input_status(0) == 'validation_invalid' && result.input_status(1) == 'inserted')
before = pg.statements.length
result = ImportUser.import([bad, { id: 8, name: 'h' }], all_or_none: true)
need('all_or_none', result.state == 'VALIDATION_REJECTED' && pg.statements.length == before)
raised = false
begin
  ImportUser.import!([bad])
rescue Kiln::DB::RecordInvalid
  raised = true
end
need('bang validation', raised && pg.statements.length == before)
raised = false
begin
  ImportUser.import([bad], raise_error: true)
rescue Kiln::DB::RecordInvalid
  raised = true
end
need('raise_error', raised)
raised = false
begin
  ImportUser.import!([bad], validate: false)
rescue Kiln::DB::RecordInvalid
  raised = true
end
need('bang always validates like AR', raised)
tracked = ImportUser.import([bad], track_validation_failures: true)
need('tracked validation failures', tracked.failed_instances[0][0] == 0 && tracked.failed_instances[0][1].equal?(bad))
need('empty import', ImportUser.bulk_import([]).num_inserts.zero?)
defaults = ImportUser.import([{}, {}])
need('default values input', defaults.num_inserts == 2 && pg.statements[-1][0] == 'INSERT INTO "users" DEFAULT VALUES')
before = pg.statements.length

rejects('unknown update column') { ImportUser.import(rows, on_duplicate_key_update: [:missing]) }
rejects('empty update columns') { ImportUser.import(rows, on_duplicate_key_update: []) }
rejects('conflicting options') { ImportUser.import(rows, on_duplicate_key_ignore: true, on_duplicate_key_update: [:name]) }
rejects('unknown options') { ImportUser.import(rows, ignore_conflict: true) }
rejects('no invented update option') { ImportUser.import(rows, conflict_update: [:name]) }
rejects('invalid row width') { ImportUser.import(%i[id name], [[1]]) }
rejects('invalid batch size') { ImportUser.import(rows, batch_size: 0) }
rejects('invalid column identifier') { ImportUser.import(rows, on_duplicate_key_update: [:'name;DROP']) }
rejects('missing update source') { ImportUser.import([{ id: 9 }], on_duplicate_key_update: [:name]) }
rejects('duplicate column keys') { ImportUser.import([{ 'id' => 1, id: 2 }]) }
rejects('unknown input column') { ImportUser.import([{ id: 1, nonsense: 2 }]) }
need('validation failures write nothing', pg.statements.length == before)

ImportStamp.define_table(:postgres, 'stamps', %w[id name created_at updated_at], ['id'], 's')
ImportStamp.import([{ id: 1, name: 'a', created_at: nil }], on_duplicate_key_update: [:name])
need('AR timestamp defaults', pg.statements[-1][0].include?('CURRENT_TIMESTAMP, CURRENT_TIMESTAMP'))
need('AR automatic update timestamp', pg.statements[-1][0].end_with?('"name" = EXCLUDED."name", "updated_at" = EXCLUDED."updated_at"'))
ImportStamp.import([{ id: 1, name: 'a' }], on_duplicate_key_update: :all)
need('all preserves creation timestamp', !pg.statements[-1][0].include?('"created_at" ='))
ImportStamp.import([{ id: 1, name: 'a' }], on_duplicate_key_update: [:name], timestamps: false)
need('timestamps false preserves exact update list', pg.statements[-1][0].end_with?('"name" = EXCLUDED."name"'))

returned = Kiln::DB::ImportResult.committed(['inserted'], [[1, 'Ada', 30]])
returned.annotate(ImportUser, [], 1, 1, ['name'])
need('AR result accessors', returned.ids == [1] && returned.results == ['Ada'] && returned.returned == [[1, 'Ada', 30]])

ImportUser.define_table(:mysql, 'users', %w[id name age], ['id'], 'u')
my = ImportConnection.new(:mysql)
Kiln::DB::Scope.use(my)
my.warnings = [['Warning', 1062, 'duplicate key']]
result = ImportUser.import(rows, on_duplicate_key_ignore: true)
need('mysql ignores duplicates without raising', result.state == 'COMMITTED' && my.commits == 1 && my.rollbacks.zero?)
need('mysql INSERT IGNORE', my.statements[-1][0].start_with?('INSERT IGNORE INTO `users`'))
my.warnings = []
ImportUser.import(rows, on_duplicate_key_update: [:name])
need('mysql update chosen columns', my.statements[-1][0].end_with?('ON DUPLICATE KEY UPDATE `name` = `kiln_new`.`name`'))
my.warnings = [['Warning', 1265, 'data truncated']]
raised = false
begin
  ImportUser.import(rows, on_duplicate_key_ignore: true)
rescue Kiln::DB::Error
  raised = true
end
need('mysql non-conflict errors roll back', raised && my.rollbacks == 1)
need('scope transaction balanced', my.depth.zero?)
Kiln::DB::Scope.use(nil)
puts 'ok ar-import'
