require 'kiln'
require 'test/support'

def check(label, passed)
  raise "FAIL #{label}" unless passed

  puts "ok   #{label}"
end

puts '-- Runtime::CpuPool: caller timeout'
cpu_t = Kiln::Runtime::CpuPool.new(1, queue: 4)
late = Queue.new
blocker = Thread.new do
  cpu_t.run(timeout: 5) do
    Kernel.sleep 0.3
    1
  end
end
Kernel.sleep 0.05
t0 = Kiln::Runtime.now
r = begin
  cpu_t.run(timeout: 0.05) do
    late << :late
    2
  end
rescue Kiln::Runtime::PoolTimeout
  :pool_timeout
rescue Kiln::Runtime::DeadlineExceeded
  :deadline
end
waited = Kiln::Runtime.now - t0
blocker.join
Kernel.sleep 0.1
check 'caller timeout -> Runtime::PoolTimeout', r == :pool_timeout && waited < 0.2
check 'expired queued task is not started', late.empty? && cpu_t.skipped >= 1

full = Kiln::Runtime::CpuPool.new(1, queue: 1)
hold = Thread.new do
  full.run(timeout: 5) do
    Kernel.sleep 0.3
    1
  end
end
Kernel.sleep 0.05
filler = Thread.new { full.run(timeout: 5) { 2 } }
Kernel.sleep 0.05
ran = Queue.new
r = begin
  full.run(timeout: 0.05) do
    ran << :ran
    3
  end
rescue Kiln::Runtime::PoolTimeout
  :pool_timeout
end
hold.join
filler.join
Kernel.sleep 0.05
check 'full queue -> Runtime::PoolTimeout, task is not run', r == :pool_timeout && ran.empty?

puts '-- Runtime::CpuPool: worker recovery'
sup = Kiln::Runtime::CpuPool.new(2, queue: 8)
check 'both workers started', sup.alive_workers == 2
r = begin
  sup.run(timeout: 2) { raise SystemExit }
rescue Kiln::Runtime::WorkerLost
  :lost
end
Kernel.sleep 0.1
check 'SystemExit in task -> Runtime::WorkerLost, worker replaced',
      r == :lost && sup.alive_workers == 2 && sup.respawned == 1
check 'pool runs tasks after worker replacement', sup.run(timeout: 2) { 21 * 2 } == 42
started = Queue.new
t0 = Kiln::Runtime.now
victim = run_lost(sup) do
  started << Thread.current
  Kernel.sleep 3
  1
end
worker = started.pop
worker.kill
r = victim.value
check 'kill during task: caller immediately gets Runtime::WorkerLost', r == :lost && Kiln::Runtime.now - t0 < 1.0
Kernel.sleep 0.1
check 'after kill: two workers restored and busy is correct', sup.alive_workers == 2 && sup.busy.zero?
late = Kiln::Runtime::CpuPool.new(1)
begin
  late.run(timeout: 0.05) do
    Kernel.sleep 0.15
    1
  end
rescue StandardError
  nil
end
Kernel.sleep 0.2
check 'task finishing after deadline is counted in overran', late.overran == 1
sup.close
r = begin
  sup.run(timeout: 1) { 1 }
rescue Kiln::Runtime::PoolTimeout => e
  e.message
end
Kernel.sleep 0.1
check 'after close: new work rejected and workers exit without replacement',
      r == 'cpu pool closed' && sup.alive_workers.zero?

puts '-- Runtime::CpuPool: deterministic interruption (test holds pool mutex)'
d1 = Kiln::Runtime::CpuPool.new(1)
lock1 = d1.instance_variable_get(:@lock)
worker1 = d1.instance_variable_get(:@threads).keys.first
lock1.lock
t0 = Kiln::Runtime.now
caller1 = run_lost(d1, timeout: 3) { 1 }
Kernel.sleep 0.1
worker1.kill
r1 = caller1.value
waited1 = Kiln::Runtime.now - t0
lock1.unlock
Kernel.sleep 0.1
check 'kill after pop, before busy accounting: immediate Runtime::WorkerLost', r1 == :lost && waited1 < 1.0
check 'busy unchanged and worker restored', d1.busy.zero? && d1.alive_workers == 1 && d1.respawned == 1
d2 = Kiln::Runtime::CpuPool.new(1)
lock2 = d2.instance_variable_get(:@lock)
worker2 = d2.instance_variable_get(:@threads).keys.first
inside = Queue.new
caller2 = run_lost(d2, timeout: 3) do
  inside << true
  Kernel.sleep 0.1
  2
end
inside.pop
lock2.lock
Kernel.sleep 0.2
worker2.kill
r2 = caller2.value
lock2.unlock
Kernel.sleep 0.1
check 'kill after task, before accounting: Runtime::WorkerLost and busy returns to 0',
      r2 == :lost && d2.busy.zero? && d2.alive_workers == 1
d3 = Kiln::Runtime::CpuPool.new(1)
running = Queue.new
caller3 = run_lost(d3) do
  running << true
  Kernel.sleep 3
  3
end
running.pop
t3 = Kiln::Runtime.now
done = d3.shutdown(grace: 0.1).zero?
r3 = caller3.value
check 'shutdown interrupts running task without replacement',
      done && r3 == :lost && d3.alive_workers.zero? && d3.respawned.zero? && Kiln::Runtime.now - t3 < 2.0
r = begin
  Kiln::Runtime::CpuPool.new(1).run(timeout: Float::INFINITY) { 1 }
rescue ArgumentError
  :rejected
end
check 'infinite timeout rejected', r == :rejected
