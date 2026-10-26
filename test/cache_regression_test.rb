require 'kiln/cache'

def verify(label, condition)
  raise "FAIL #{label}" unless condition

  puts "ok   #{label}"
end

def invalid_argument?
  yield
  false
rescue ArgumentError
  true
end

def closed_error?
  yield
  false
rescue IOError
  true
end

cache = Kiln::Cache.new(max_entries: 1024, max_bytes: 1 << 20, shards: 4)
key = +'copy'
value = +'original'
cache.set(key, value)
key << ':changed'
value << ':changed'
copy = cache.get('copy')
copy << ':changed'
verify 'set owns its bytes and get returns an independent copy', cache.get('copy') == 'original'
verify 'empty keys and values round-trip', cache.set('', '') && cache.get('') == ''
verify 'a key of exactly 64 KiB is accepted', cache.set('k' * 65_536, 'limit') && cache.get('k' * 65_536) == 'limit'
ttl_capped = cache.set('far', 'future', ttl: Float::MAX) &&
             cache.get('far') == 'future' &&
             Kiln::Cache::Limits.ttl_ms(Float::MAX) == Kiln::Cache::MAX_TTL * 1000
verify 'huge finite TTLs are capped before multiplication', ttl_capped
verify 'zero and NaN TTLs are rejected', invalid_argument? { cache.set('bad', 'v', ttl: 0) } &&
                                         invalid_argument? { cache.set('bad', 'v', ttl: Float::NAN) }
max_bytes_rejected = invalid_argument? do
  Kiln::Cache.new(max_entries: 10, max_bytes: 1 << 64)
end
sweep_budget_rejected = invalid_argument? { cache.sweep(1 << 64) }
verify 'max_bytes cannot overflow the FFI C long', max_bytes_rejected
verify 'sweep budgets cannot overflow the FFI C long', sweep_budget_rejected
excess_capacity_rejected = invalid_argument? do
  Kiln::Cache.new(max_entries: Kiln::Cache::MAX_ENTRIES + 1, max_bytes: 1 << 20)
end
verify 'excessive index capacities are rejected', excess_capacity_rejected

sweeper = Kiln::Cache.new(max_entries: 1024, max_bytes: 1 << 20, shards: 4)
128.times { |index| sweeper.set("s#{index}", 'v', ttl: 0.01) }
Kernel.sleep 0.04
before = sweeper.stats
verify 'sweep zero leaves all counters unchanged', sweeper.sweep(0).zero? && sweeper.stats == before
bounded = 512.times.all? { sweeper.sweep(1).between?(0, 1) }
verify 'small sweep budgets rotate through every shard', bounded && sweeper.stats[:entries].zero? &&
                                                         sweeper.stats[:expirations] == 128
sweeper.close

alias_cache = cache.dup
cache.close
verify 'copies observe the same native closed state', alias_cache.closed? &&
                                                      closed_error? { alias_cache.get('copy') }
verify 'every operation reports a closed cache', closed_error? { cache.set('x', 'v') } &&
                                                 closed_error? { cache.delete('x') } &&
                                                 closed_error? { cache.sweep(0) } &&
                                                 closed_error? { cache.clear } &&
                                                 closed_error? { cache.stats }
cache.close
alias_cache.close

racer = Kiln::Cache.new(max_entries: 256, max_bytes: 1 << 20, shards: 8)
started = Queue.new
errors = Queue.new
threads = Array.new(8) do |index|
  Thread.new do
    started << index
    begin
      2000.times do |step|
        key = "r:#{index}:#{step % 16}"
        case step % 6
        when 0 then racer.set(key, key)
        when 1 then racer.get(key)
        when 2 then racer.delete(key)
        when 3 then racer.sweep(1)
        when 4 then racer.stats
        else racer.clear
        end
      end
    rescue IOError
      nil
    rescue StandardError => e
      errors << e.class.to_s
    end
  end
end
8.times { started.pop }
closers = Array.new(4) { Thread.new { racer.close } }
closers.each(&:join)
threads.each(&:join)
replacement = Kiln::Cache.new(max_entries: 16, max_bytes: 4096, shards: 1)
replacement.set('sentinel', 'new')
stale_write_rejected = closed_error? { racer.set('sentinel', 'old') }
replacement_intact = replacement.get('sentinel') == 'new'
closed = racer.closed?
no_errors = errors.empty?
close_state_valid = closed && no_errors && stale_write_rejected && replacement_intact
verify 'concurrent operations and repeated close preserve the replacement', close_state_valid
replacement.close

locals = Array.new(4) do |index|
  local = Kiln::Cache.new(max_entries: 8, max_bytes: 4096, shards: 1)
  local.set('k', "v#{index}")
  (index + 1).times { local.get('k') }
  local
end
snapshots = Queue.new
readers = Array.new(4) do |index|
  Thread.new do
    200.times do
      snapshot = locals[index].stats
      snapshots << index unless snapshot[:entries] == 1 && snapshot[:hits] == index + 1
    end
  end
end
collector = Thread.new { 30.times { GC.start } }
readers.each(&:join)
collector.join
verify 'statistics snapshots remain separate during concurrent GC', snapshots.empty?
locals.each(&:close)
