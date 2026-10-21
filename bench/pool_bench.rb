require 'kiln'

iterations = Integer(ARGV[0] || ENV.fetch('ITERATIONS') { '10000000' })
pool = Kiln::Runtime::Pool.new(1) { Object.new }
value = nil
started = Kiln::Runtime.now
iterations.times do
  value = pool.with { |resource| resource }
end
raise 'pool result missing' unless value

puts "iterations=#{iterations} seconds=#{(Kiln::Runtime.now - started).round(3)}"
