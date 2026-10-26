require 'kiln/cache'

module Kiln
  class Cache
    def gc_test_handle = @handle
  end
end

module CacheGcNative
  ffi_func :cache_gc_start, [:long], :long, blocking: true
  ffi_func :cache_gc_waiting, [], :long
  ffi_func :cache_gc_release, [], :long, blocking: true
  ffi_func :cache_gc_join, [], :long, blocking: true
end

operation = ARGV.fetch(0) { 'get' }
raise 'unknown cache operation' unless %w[get set delete].include?(operation)

cache = Kiln::Cache.new(shards: 1, max_entries: 8, max_bytes: 4096, max_value: 256)
handle = cache.gc_test_handle
raise 'cache setup failed' unless cache.set('k', 'v')
raise 'holder setup failed' unless CacheGcNative.cache_gc_start(handle).zero?

reader = Thread.new do
  busy = false
  600.times do
    Kiln::Cache::Native.kiln_cache_get_try(handle, 'k', 1)
    busy = Kiln::Cache::Native.kiln_cache_found == Kiln::Cache::BUSY
    break if busy

    Kernel.sleep(0.005)
  end
  raise 'the try path did not report a busy shard' unless busy

  case operation
  when 'get'
    raise 'wrong value' unless cache.get('k') == 'v'
  when 'set'
    raise 'write failed' unless cache.set('k', 'w')
  when 'delete'
    raise 'delete failed' unless cache.delete('k')
  end
end
waiting = false
3000.times do
  if CacheGcNative.cache_gc_waiting == 1
    waiting = true
    break
  end
  Kernel.sleep(0.001)
end
raise 'reader did not enter the cache' unless waiting

GC.start
expired = CacheGcNative.cache_gc_release
reader.join
CacheGcNative.cache_gc_join
cache.close
raise 'GC waited for a worker blocked on the cache mutex' unless expired.zero?

puts "cache GC: collection completed while public #{operation} waited for a held shard mutex"
