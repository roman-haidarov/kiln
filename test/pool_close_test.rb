require "kiln"
require "socket"

def check(label, ok)
  raise "FAIL #{label}" unless ok
  puts "ok   #{label}"
end

class FatalClose < Exception; end

live = []
failed = Kiln::Pool.new(1, close: ->(_resource) { raise IOError, "close failed" }) do
  resource, peer = Socket.pair(Socket::AF_UNIX, Socket::SOCK_STREAM, 0)
  peer.close
  live << resource
  resource
end
begin
  failed.with { raise IOError, "discard" }
rescue IOError
  nil
end
blocked = begin
  failed.with(timeout: 0.02) { |_resource| nil }
  false
rescue Kiln::PoolTimeout
  true
end
check "close failure preserves physical capacity limit", blocked && live.size == 1 && !live[0].closed? && failed.close_failures == 1 && failed.quarantined == 1 && failed.available == 0 && failed.consistent?
live.each(&:close)

made = 0
stale = Kiln::Pool.new(1, validate: ->(_resource) { false }, close: ->(_resource) { raise FatalClose, "interrupted" }) do
  made += 1
  Object.new
end
stale.with { |_resource| nil }
fatal = begin
  stale.with { |_resource| nil }
  false
rescue FatalClose
  true
end
check "fatal stale-close error is counted without creating a new resource", fatal && made == 1 && stale.close_failures == 1 && stale.quarantined == 1 && stale.available == 0 && stale.consistent?

entered = Queue.new
gate = Queue.new
killed = Kiln::Pool.new(1, close: ->(_resource) { entered << true; gate.pop }) { Object.new }
victim = Thread.new do
  killed.with { raise IOError, "discard" }
rescue IOError
  nil
end
entered.pop
victim.kill
victim.join
check "interrupted close keeps its slot", killed.close_failures == 1 && killed.quarantined == 1 && killed.available == 0 && killed.consistent?

ordered = Kiln::Pool.new(1, close: ->(_resource) { true }) { Object.new }
begin
  ordered.with { raise IOError, "discard" }
rescue IOError
  nil
end
events = ordered.instance_variable_get(:@events)
started = events.pop
finished = events.pop
dead = Thread.new { true }
dead.join
started[1].thread = dead
events << started
check "close thread exit keeps its slot quarantined", ordered.close_abandoned == 1 && ordered.quarantined == 1 && ordered.closing == 0 && ordered.consistent?
events << finished
events << finished
check "late duplicate result releases the slot only once", ordered.available == 1 && ordered.quarantined == 0 && ordered.closing == 0 && ordered.consistent?

puts "-- quarantine: release and policy"
QConn = Struct.new(:n)
gate_c = 0
stale_retry = Kiln::Pool.new(2, validate: ->(c) { c.n != 1 }, close: ->(_c) { raise IOError, "close failed" }) do
  gate_c += 1
  QConn.new(gate_c)
end
stale_retry.with { |c| c.n }
got = stale_retry.with(timeout: 1) { |c| c.n }
check "stale resource close failure quarantined; another resource checked out", got == 2 && stale_retry.quarantined == 1 && stale_retry.close_failures == 1 && stale_retry.consistent?
released = stale_retry.release_quarantined
check "release_quarantined restores capacity", released == 1 && stale_retry.quarantined == 0 && stale_retry.available == 2 && stale_retry.consistent?
lenient = Kiln::Pool.new(1, discard: ->(_e) { true }, close: ->(_c) { raise IOError, "close failed" }, on_close_failure: :release) { QConn.new(1) }
begin
  lenient.with { raise IOError, "drop" }
rescue IOError
  nil
end
check "on_close_failure: :release restores capacity immediately", lenient.available == 1 && lenient.quarantined == 0 && lenient.close_failures == 1 && lenient.consistent?
class GatedEvents
  attr_reader :entered, :gate

  def initialize(queue)
    @queue = queue
    @entered = Queue.new
    @gate = Queue.new
    @armed = true
  end

  def <<(event)
    @queue << event
  end

  def pop
    @queue.pop
  end

  def empty?
    result = @queue.empty?
    if result && @armed
      @armed = false
      @entered << true
      @gate.pop
    end
    result
  end
end

close_entered = Queue.new
close_gate = Queue.new
released_race = Kiln::Pool.new(1, on_close_failure: :release,
                               close: ->(_resource) { close_entered << true; close_gate.pop; true }) { Object.new }
closer_thread = Thread.new do
  begin
    released_race.with { raise IOError, "discard" }
  rescue IOError
    nil
  end
end
close_entered.pop(timeout: 1)
released_race.closing
source_events = released_race.instance_variable_get(:@events)
gated_events = GatedEvents.new(source_events)
released_race.instance_variable_set(:@events, gated_events)
drainer_thread = Thread.new { released_race.available }
gated_events.entered.pop(timeout: 1)
close_gate << true
closer_thread.join
gated_events.gate << true
drainer_thread.join
check "late close success does not release capacity twice after manual release", released_race.available == 1 && released_race.quarantined == 0 && released_race.close_abandoned == 1 && released_race.consistent?

[0.5, "1", -2].each do |count|
  rejected = begin
    released_race.release_quarantined(count)
    false
  rescue ArgumentError
    true
  end
  check "release_quarantined rejects invalid count", rejected
end

r = begin
      Kiln::Pool.new(1, on_close_failure: :ignore) { QConn.new(1) }
      :accepted
    rescue ArgumentError
      :rejected
    end
check "unknown close-failure policy is rejected", r == :rejected

