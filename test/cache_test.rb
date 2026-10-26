require 'kiln'
require 'socket'
require 'stringio'
require 'test/support'

def check(label, passed)
  raise "FAIL #{label}" unless passed

  puts "ok   #{label}"
end

def rejected?
  yield
  false
rescue ArgumentError, TypeError
  true
end

cache = Kiln::Cache.new(max_entries: 1000, max_bytes: 1 << 20, shards: 4)
check 'a missing key returns nil', cache.get('nope').nil?
check 'set then get returns the value', cache.set('a', 'one') && cache.get('a') == 'one'
check 'an empty value is a hit, not a miss', cache.set('empty', '') && cache.get('empty') == ''
binary_key = "k\x00z".b
binary_value = "\x00\xFFv".b
cache.set(binary_key, binary_value)
check 'binary keys and values with NUL bytes round-trip',
      cache.get(binary_key) == binary_value && cache.get('k').nil?
check 'a stored value comes back as binary bytes',
      cache.set('u', 'один') && cache.get('u').force_encoding(Encoding::UTF_8) == 'один'
before = cache.stats[:entries]
cache.set('a', 'two')
check 'set replaces the value of an existing key', cache.get('a') == 'two' && cache.stats[:entries] == before
check 'delete removes a key once', cache.delete('a') && cache.get('a').nil? && !cache.delete('a')
cache['b'] = 'bee'
check '[]= and [] are set and get', cache['b'] == 'bee'
computed = 0
first = cache.fetch('f') do
  computed += 1
  'made'
end
second = cache.fetch('f') do
  computed += 1
  'again'
end
check 'fetch computes a missing value once', first == 'made' && second == 'made' && computed == 1

cache.set('t', 'short-lived', ttl: 0.03)
fresh = cache.get('t')
Kernel.sleep 0.09
check 'a value expires after its ttl', fresh == 'short-lived' && cache.get('t').nil? && cache.stats[:expirations] >= 1
20.times { |index| cache.set("s#{index}", 'x', ttl: 0.03) }
Kernel.sleep 0.09
swept = cache.sweep(10_000)
check 'sweep removes expired values', swept == 20 && (0...20).none? { |index| cache.get("s#{index}") }

small = Kiln::Cache.new(max_entries: 100, max_bytes: 1 << 16, max_value: 10, shards: 1)
check 'a value over max_value is refused', !small.set('big', 'x' * 11) && small.get('big').nil?
small.set('k', 'short')
refused = small.set('k', 'x' * 11)
check 'a refused set removes the previous value of the key', !refused && small.get('k').nil?
check 'refusals are counted', small.stats[:refusals] == 2

sieve = Kiln::Cache.new(max_entries: 8, max_bytes: 1 << 20, shards: 1)
8.times { |index| sieve.set("k#{index}", "v#{index}") }
4.times { |index| sieve.get("k#{index}") }
4.times { |index| sieve.set("n#{index}", "w#{index}") }
kept = (0...4).all? { |index| sieve.get("k#{index}") == "v#{index}" }
gone = (4...8).none? { |index| sieve.get("k#{index}") }
check 'SIEVE keeps entries that were read and evicts the ones that were not',
      kept && gone && sieve.stats[:entries] == 8 && sieve.stats[:evictions] == 4

bytes = Kiln::Cache.new(max_entries: 1000, max_bytes: 2000, shards: 1)
10.times { |index| bytes.set("b#{index}", 'y' * 300) }
check 'the byte limit evicts older values', bytes.stats[:bytes] <= 2000 && bytes.stats[:evictions].positive?
check 'stats report every counter',
      cache.stats.keys == %i[entries bytes hits misses evictions expirations refusals] &&
      cache.stats[:hits].positive? && cache.stats[:misses].positive?
cleared = cache.clear
check 'clear empties the cache', cleared.positive? && cache.stats[:entries].zero? && cache.get('b').nil?

check('shards must be a power of two',
      rejected? { Kiln::Cache.new(max_entries: 10, max_bytes: 1000, shards: 3) })
check 'limits must be positive', rejected? { Kiln::Cache.new(max_entries: 0, max_bytes: 1000) } &&
                                 rejected? { Kiln::Cache.new(max_entries: 10, max_bytes: -1) }
check 'ttl must be positive and finite', rejected? { cache.set('x', 'y', ttl: -1) } &&
                                         rejected? { cache.set('x', 'y', ttl: Float::INFINITY) }
check('values must be Strings', rejected? { cache.set('x', 42) })
check('keys are limited to 64 KiB', rejected? { cache.get('k' * 65_537) })
tiny = Kiln::Cache.new(max_entries: 2, max_bytes: 1 << 16, shards: 16)
check 'shards shrink to fit max_entries', tiny.shards == 2

closing = Kiln::Cache.new(max_entries: 10, max_bytes: 1000)
closing.close
closed_error = begin
  closing.get('a')
  false
rescue IOError
  true
end
check 'a closed cache raises IOError', closing.closed? && closed_error
closing.close

shared = Kiln::Cache.new(max_entries: 64, max_bytes: 1 << 16, max_value: 256, shards: 8)
failures = Queue.new
workers = Array.new(8) do |thread_index|
  Thread.new do
    2000.times do |step|
      key = "key#{((step * 7) + (thread_index * 13)) % 96}"
      case step % 4
      when 0, 1
        shared.set(key, "#{key}|#{thread_index}|#{step}")
      when 2
        value = shared.get(key)
        failures << key if value && !value.start_with?("#{key}|")
      else
        shared.delete(key) if (step % 16) == 3
      end
    end
  end
end
workers.each(&:join)
limits = shared.stats
check 'concurrent threads never read another key\'s value and limits hold',
      failures.empty? && limits[:entries] <= 64 && limits[:bytes] <= 1 << 16

log = Kiln::Observability::Log.new(StringIO.new)
pages = Kiln::Cache.new(max_entries: 256, max_bytes: 1 << 20)
router = Kiln::Routing::Router.new
router.get('/c/:key', lambda { |ctx|
  key = ctx.req.params['key']
  ctx.res.text(pages.fetch(key) { "value-of-#{key}" })
})
router.seal!
[[:event, {}], [:event, { handlers: 2 }], [:base, {}]].each do |backend, extra|
  label = extra.empty? ? backend.to_s : "#{backend} lanes"
  server = Kiln::Server.new(router, log: log, backend: backend, host: '127.0.0.1', port: 0, **extra)
  server.start
  port = server.port
  wrong = Queue.new
  clients = Array.new(4) do |client|
    Thread.new do
      25.times do |step|
        key = "k#{((client * 25) + step) % 40}"
        reply = exchange(port, "GET /c/#{key} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        wrong << key unless reply.start_with?('HTTP/1.1 200 ') && reply.end_with?("value-of-#{key}")
      end
    end
  end
  clients.each(&:join)
  server.shutdown(grace: 1.0)
  check "#{label}: handlers share one cache across requests", wrong.empty? && pages.stats[:hits].positive?
end
pages.close
log.close
