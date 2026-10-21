require 'kiln'

n = Integer(ARGV[0] || '100000')
pool = Kiln::Runtime::CpuPool.new(1)
start = Kiln::Runtime.now
n.times { pool.run { 42 } }
puts "iterations=#{n} seconds=#{Kiln::Runtime.now - start}"
pool.close
raise 'workers did not stop' unless pool.wait_stopped?(5)
