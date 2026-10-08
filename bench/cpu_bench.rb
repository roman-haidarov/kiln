require "kiln"

n = Integer(ARGV[0] || "100000")
pool = Kiln::CpuPool.new(1)
start = Kiln.now
n.times { pool.run { 42 } }
puts "iterations=#{n} seconds=#{Kiln.now-start}"
pool.close
raise "workers did not stop" unless pool.await_workers(5)
