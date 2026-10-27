require 'kiln/db'

Thread.current

class CompileBenchUser < Kiln::DB::Model
end
CompileBenchUser.define_table(:postgres, 'users', %w[id name age active], ['id'], 'u')

def compile_case(kind, iterations)
  u = CompileBenchUser.table
  i = 0
  checksum = 0
  while i < iterations
    rel = if kind == :hot
            CompileBenchUser.where(id: i).order(u[:id].asc).limit(1).select(u[:name])
          elsif kind == :offset
            CompileBenchUser.where(id: i).order(u[:id].asc).limit(1).offset(2).select(u[:name])
          elsif kind == :unique
            CompileBenchUser.where(id: i).limit(i + 100_000).select(u[:name])
          else
            CompileBenchUser.where(name: "n#{i}").limit(3).select(u[:age])
          end
    compiled = rel.compile
    checksum += compiled[0].length + compiled[1].length
    i += 1
  end
  checksum
end

def measure(label, kind, iterations)
  start = Kiln::Runtime.now
  sum = compile_case(kind, iterations)
  elapsed = Kiln::Runtime.now - start
  print "#{label} ns_per_call #{(elapsed * 1e9 / iterations).round} checksum #{sum}\n"
end

iterations = ENV.fetch('KILN_ORM_BENCH_ITERATIONS', '100000').to_i
raise 'positive iteration count required' unless iterations.positive?

compile_case(:hot, 3000)
compile_case(:offset, 1000)
3.times do
  measure('hot', :hot, iterations)
  measure('offset', :offset, iterations)
end

4.times do
  start = Kiln::Runtime.now
  jobs = []
  4.times { jobs << Thread.new { compile_case(:hot, iterations / 4) } }
  jobs.each(&:join)
  print "threads4 elapsed_ms #{((Kiln::Runtime.now - start) * 1000).round(2)}\n"
end

u = CompileBenchUser.table
i = 0
while i < 4200
  CompileBenchUser.where(id: i).order(u[:id].asc).limit(i).select(u[:name]).compile
  i += 1
end
3.times { measure('new_shape_after_saturation', :new_shape, iterations) }
3.times { measure('unique_shapes', :unique, iterations) }
