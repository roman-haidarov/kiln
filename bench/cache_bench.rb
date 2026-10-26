require 'kiln'
require 'bench/cache_stores'

def percentile(sorted, fraction)
  index = (sorted.size * fraction).floor
  index = sorted.size - 1 if index >= sorted.size
  sorted[index]
end

store_name = ENV.fetch('STORE') { 'native' }
copy_values = store_name == 'native' || ENV.fetch('COPY') { '0' } == '1'
keys = Integer(ENV.fetch('KEYS') { '100000' })
value_bytes = Integer(ENV.fetch('VALUE') { '256' })
ops = Integer(ENV.fetch('OPS') { '1000000' })
reads = Integer(ENV.fetch('READS') { '90' })
thread_count = Integer(ENV.fetch('THREADS') { '1' })
capacity = Integer(ENV.fetch('CAPACITY') { keys.to_s })
skew = ENV.fetch('SKEW') { '0' } == '1'
requested_shards = Integer(ENV.fetch('SHARDS') { '16' })
raise ArgumentError, 'STORE must be native or hash' unless %w[native hash].include?(store_name)
unless [keys, capacity, ops, thread_count].all?(&:positive?)
  raise ArgumentError, 'KEYS, CAPACITY, OPS and THREADS must be positive'
end
unless value_bytes >= 0 && reads >= 0 && reads <= 100
  raise ArgumentError, 'VALUE must be non-negative and READS must be from 0 to 100'
end

shards = Kiln::Cache::Limits.shards(requested_shards, capacity, capacity * (value_bytes + 192) * 2)
store = if store_name == 'hash'
          CacheHashStore.new(capacity, shards, copy: copy_values)
        else
          CacheNativeStore.new(capacity, value_bytes, shards)
        end
capacity.times { |index| store.put("key:#{index}", 'v' * value_bytes) }

started = Kiln::Runtime.now
results = Array.new(thread_count) do |thread_index|
  Thread.new do
    per_thread = (ops / thread_count) + (thread_index < ops % thread_count ? 1 : 0)
    samples = Array.new(per_thread, 0.0)
    state = ((thread_index * 2_654_435_761) + 1) % 2_147_483_648
    hits = 0
    reads_done = 0
    per_thread.times do |step|
      state = ((state * 1_103_515_245) + 12_345) % 2_147_483_648
      slot = if skew
               unit = ((state >> 7) % 1_000_000) / 1_000_000.0
               (unit * unit * unit * keys).floor
             else
               (state >> 7) % keys
             end
      key = "key:#{slot}"
      before = Kiln::Runtime.now
      if (state % 100) < reads
        reads_done += 1
        if store.get(key)
          hits += 1
        else
          store.put(key, 'v' * value_bytes)
        end
      else
        store.put(key, 'v' * value_bytes)
      end
      samples[step] = Kiln::Runtime.now - before
    end
    [samples, hits, reads_done]
  end
end.map(&:value)
elapsed = Kiln::Runtime.now - started

all = []
hits = 0
reads_done = 0
results.each do |samples, thread_hits, thread_reads|
  all.concat(samples)
  hits += thread_hits
  reads_done += thread_reads
end
all.sort!
micro = ->(seconds) { (seconds * 1_000_000).round(2) }
puts "store=#{store_name} workers=#{ENV.fetch('SPINEL_WORKERS') { '1' }} " \
     "threads=#{thread_count} keys=#{keys} capacity=#{capacity} shards=#{shards} " \
     "copy=#{copy_values} skew=#{skew} value=#{value_bytes} reads=#{reads}% ops=#{all.size} entries=#{store.size}"
ratio = reads_done.zero? ? 'n/a' : "#{(hits * 100.0 / reads_done).round(1)}%"
rate = (all.size / elapsed).round
p50 = micro.call(percentile(all, 0.50))
p99 = micro.call(percentile(all, 0.99))
p999 = micro.call(percentile(all, 0.999))
maximum = micro.call(all.last)
puts "  reads_done=#{reads_done} hits=#{hits} hit_ratio=#{ratio} ops/s=#{rate} p50=#{p50}us " \
     "p99=#{p99}us p999=#{p999}us max=#{maximum}us"
store.close
