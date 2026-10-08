require "kiln"

def check(label, ok)
  raise "FAIL #{label}" unless ok
  puts "ok   #{label}"
end

def read_until_closed(sock, seconds)
  data = (+"").b
  reader = Thread.new do
    Thread.current.report_on_exception = false
    loop do
      chunk = begin
                sock.readpartial(65_536)
              rescue EOFError, IOError, SystemCallError
                nil
              end
      break unless chunk
      data << chunk
    end
  end
  deadline = Kiln.now + seconds
  Kernel.sleep 0.01 while reader.alive? && Kiln.now < deadline
  if reader.alive?
    begin
      sock.close
    rescue IOError, SystemCallError
      nil
    end
    reader.kill
    cleanup_deadline = Kiln.now + 0.5
    Kernel.sleep 0.001 while reader.alive? && Kiln.now < cleanup_deadline
  end
  data
end

def wait_for
  limit = Kiln.now + 3
  until yield
    raise "wait timeout" if Kiln.now >= limit
    Kernel.sleep 0.01
  end
end

class FailingSpawn < Kiln::CpuPool
  attr_accessor :failures
  def spawn_one
    if @failures && @failures > 0
      @failures -= 1
      raise ThreadError, "injected spawn failure"
    end
    super
  end
end

retry_pool = FailingSpawn.new(1)
retry_pool.failures = 2
r = begin
  retry_pool.run { raise SystemExit }
rescue Kiln::WorkerLost
  :lost
end
wait_for { retry_pool.alive_workers == 1 && retry_pool.spawn_failures == 2 && retry_pool.respawned == 1 }
check "spawn failure retries and restores worker", r == :lost && retry_pool.respawned == 1 && retry_pool.run { 42 } == 42
retry_pool.shutdown(grace: 0.1)

class GatedSpawn < Kiln::CpuPool
  attr_accessor :gate, :entered, :results
  def spawn_one
    if @gate
      @entered << true
      @gate.pop
    end
    result = super
    @results << result if @results
    result
  end
end

gated = GatedSpawn.new(1)
gate = Queue.new
gate_entered = Queue.new
gated.gate = gate
gated.entered = gate_entered
spawn_results = Queue.new
gated.results = spawn_results
gated.run { raise SystemExit } rescue Kiln::WorkerLost
check "replacement reached the gate", gate_entered.pop(timeout: 1) == true
gated.close
gate << true
check "replacement after close does not call Thread.new", spawn_results.pop(timeout: 1) == false
check "close during replacement leaves no new worker", gated.await_workers(1) && gated.alive_workers == 0 && gated.instance_variable_get(:@threads).empty?

queued_pool = Kiln::CpuPool.new(1, queue: 4)
entered = Queue.new
running = Thread.new do
  queued_pool.run(timeout: 5) { entered << true; Kernel.sleep 5; 7 }
rescue Kiln::WorkerLost
  :lost
end
entered.pop
queued = Thread.new do
  queued_pool.run(timeout: 5) { 8 }
rescue Kiln::WorkerLost
  :lost
end
wait_for { queued_pool.queued == 1 }
started = Kiln.now
check "shutdown rejects both running and queued tasks", queued_pool.shutdown(grace: 0) && running.value == :lost && queued.value == :lost && Kiln.now - started < 1
check "shutdown is safe to call again", queued_pool.shutdown(grace: 0) && queued_pool.busy == 0 && queued_pool.alive_workers == 0

lock_pool = Kiln::CpuPool.new(1)
lock = lock_pool.instance_variable_get(:@lock)
entered = Queue.new
waiter = Thread.new do
  lock_pool.run(timeout: 3) { entered << Thread.current; Kernel.sleep 5 }
rescue Kiln::WorkerLost
  :lost
end
worker = entered.pop
lock.lock
worker.kill
check "cleanup of killed worker does not wait for mutex", waiter.value == :lost
Kernel.sleep 0.03
check "worker exits while mutex is held", !worker.alive?
lock.unlock
wait_for { lock_pool.alive_workers == 1 && lock_pool.busy == 0 }
lock_pool.shutdown(grace: 0)

stale_closes = Queue.new
stale_entered = Queue.new
stale_pool = Kiln::Pool.new(1, validate: ->(_resource) { false }, close: ->(_resource) { stale_closes << true; stale_entered << true; Kernel.sleep 5 }) { Object.new }
stale_pool.with { |r| r }
victim = Thread.new { stale_pool.with { |r| r } }
stale_entered.pop
victim.kill
victim.join
check "kill during stale resource close does not close twice", stale_closes.size == 1 && stale_pool.consistent? && stale_pool.close_failures == 1 && stale_pool.quarantined == 1 && stale_pool.available == 0 && stale_pool.checked_out == 0

invalid_pool = Kiln::CpuPool.new(1)
[Float::INFINITY, 0.0 / 0.0, -2].each do |value|
  rejected = begin
    invalid_pool.await_workers(value)
    false
  rescue ArgumentError
    true
  end
  check "await_workers rejects invalid timeout", rejected
end
[Float::INFINITY, 0.0 / 0.0, -1].each do |value|
  rejected = begin
    invalid_pool.shutdown(grace: value)
    false
  rescue ArgumentError
    true
  end
  check "shutdown rejects invalid grace", rejected && !invalid_pool.closed?
end
invalid_pool.shutdown(grace: 0)

require "stringio"
class ClosedFlagSocket
  def initialize
    @closed = false
  end

  def closed? = @closed

  def close
    @closed = true
  end
end

server = Kiln::Server.new(nil, nil, log: Kiln::Log.new(StringIO.new), port: 0, host: "127.0.0.1", max_conns: 1)
server.instance_variable_set(:@finished, Queue.new)
server.instance_variable_set(:@reap_wake, SizedQueue.new(1))
reader = ClosedFlagSocket.new
server.instance_variable_get(:@slots).pop
slot = Kiln::Server::Slot.new(nil, reader, 0.0, :idle, false, false, -1)
server.send(:heap_push, slot)
server.send(:heap_remove, slot)
lock = server.instance_variable_get(:@lock)
gate = Queue.new
lock.lock
victim = Thread.new do
  begin
    gate.pop
  ensure
    server.send(:finish, slot)
  end
end
slot.thread = victim
server.instance_variable_get(:@conns)[victim] = slot
gate << true
Kernel.sleep 0.03
check "connection ensure completes while server mutex is held", !victim.alive?
lock.unlock
server.send(:settle_finished)
check "connection cleanup closes socket and returns exactly one slot", reader.closed? && server.in_flight == 0

check "Content-Length at int64 boundary is compared without overflow", Kiln::HttpSyntax.content_length({"content-length" => "9999999999999999999"}, 9223372036854775807) == :too_long
check "int64 Content-Length accepted without a hidden limit", Kiln::HttpSyntax.content_length({"content-length" => "9223372036854775807"}, 9223372036854775807) == 9223372036854775807
class FailingConstructor < Kiln::CpuPool
  def spawn_one
    @attempt = (@attempt || 0) + 1
    raise ThreadError, "constructor spawn failure" if @attempt == 2
    super
  end
end
before = Thread.list.size
rejected = begin
  FailingConstructor.new(2)
  false
rescue ThreadError
  true
end
Kernel.sleep 0.05
check "constructor failure closes workers already started", rejected && Thread.list.size == before

expiry_pool = Kiln::CpuPool.new(1)
lock = expiry_pool.instance_variable_get(:@lock)
ran = Queue.new
lock.lock
caller = Thread.new do
  expiry_pool.run(timeout: 0.03) { ran << true; 1 }
rescue Kiln::PoolTimeout
  :timeout
end
Kernel.sleep 0.08
check "deadline while waiting for CPU accounting returns timeout", caller.value == :timeout
lock.unlock
wait_for { expiry_pool.skipped == 1 }
check "task does not start after deadline while waiting for mutex", ran.empty? && expiry_pool.busy == 0
expiry_pool.shutdown(grace: 0)

check "Connection close takes precedence over HTTP/1.0 keep-alive", !Kiln::HttpSyntax.persistent?("1.0", "keep-alive, close")

overrun_pool = Kiln::CpuPool.new(1)
begin
  overrun_pool.run(timeout: 0.05) { Kernel.sleep 0.15; 1 }
rescue Kiln::PoolTimeout
  nil
end
wait_for { overrun_pool.overran == 1 }
check "overran_seconds reports work time beyond deadline", overrun_pool.overran_seconds > 0.04 && overrun_pool.busy == 0
overrun_pool.shutdown(grace: 0)

batch_pool = Kiln::Pool.new(2) { Object.new }
held = Queue.new
release_holders = Queue.new
holders = 2.times.map do
  Thread.new { batch_pool.with { |_r| held << true; release_holders.pop } }
end
2.times { held.pop }
entered = Queue.new
release_users = Queue.new
users = 2.times.map do
  Thread.new do
    batch_pool.with(timeout: 0.2) { |_r| entered << true; release_users.pop }
  rescue Kiln::PoolTimeout
    entered << false
  end
end
wait_for { users.all? { |thread| thread.status == "sleep" } }
lock = batch_pool.instance_variable_get(:@lock)
lock.lock
2.times { release_holders << true }
holders.each(&:join)
lock.unlock
first = entered.pop(timeout: 0.1)
second = entered.pop(timeout: 0.03)
2.times { release_users << true }
users.each(&:join)
check "batched returns wake all waiters without polling", first == true && second == true && batch_pool.available == 2 && batch_pool.consistent?

join_gate = Queue.new
join_entered = Queue.new
join_victim = Thread.new { join_entered << true; join_gate.pop }
join_entered.pop
started = Kiln.now
joined = server.send(:quiet_join, join_victim)
check "server wait is bounded while thread is alive", !joined && join_victim.alive? && Kiln.now - started < 1.0
join_gate << true
join_victim.join
check "server wait recognizes an exited thread", server.send(:quiet_join, join_victim)

