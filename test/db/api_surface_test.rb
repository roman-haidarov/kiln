require 'kiln/db'

files = [
  'kiln/db.rb',
  'kiln/db/async.rb',
  'kiln/db/batch.rb',
  'kiln/db/connection.rb',
  'kiln/db/errors.rb',
  'kiln/db/number.rb',
  'kiln/db/expr.rb',
  'kiln/db/sql.rb',
  'kiln/db/schema.rb',
  'kiln/db/model.rb',
  'kiln/db/native.rb',
  'kiln/db/pool.rb',
  'kiln/db/relation.rb',
  'kiln/db/scope.rb',
  'kiln/db/view.rb',
  'kiln/db/dialect/mysql.rb',
  'kiln/db/dialect/postgres.rb'
]

needles = [
  'def insert_all',
  'def self.insert_all',
  'def upsert_all',
  'def self.upsert_all',
  'def upsert',
  'def self.upsert'
]

bad = 0
files.each do |path|
  text = File.read(path)
  needles.each do |needle|
    next unless text.include?(needle)

    print 'forbidden '
    print path
    print ' '
    print needle
    print "\n"
    bad += 1
  end
end

mods = [Kiln::DB::Model, Kiln::DB::Batch, Kiln::DB::Relation]
mods.each do |mod|
  if mod.respond_to?(:insert_all) || mod.respond_to?(:upsert_all) || mod.respond_to?(:upsert)
    print 'forbidden singleton '
    print mod.name
    print "\n"
    bad += 1
  end
end

print 'forbidden='
print bad
print "\n"
raise 'forbidden public bulk name' unless bad.zero?

print "ok api_surface\n"
