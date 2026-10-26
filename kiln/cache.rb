module Kiln
  class Cache
    module Native
      ffi_func :kiln_cache_new, %i[long long long long], :long, blocking: true
      ffi_func :kiln_cache_open, [:long], :long
      ffi_func :kiln_cache_set_try, %i[long str long str long long], :long
      ffi_func :kiln_cache_set, %i[long str long str long long], :long, blocking: true
      ffi_func :kiln_cache_get_try, %i[long str long], :binstr
      ffi_func :kiln_cache_get, %i[long str long], :binstr, blocking: true
      ffi_func :kiln_cache_found, [], :long
      ffi_func :kiln_cache_delete_try, %i[long str long], :long
      ffi_func :kiln_cache_delete, %i[long str long], :long, blocking: true
      ffi_func :kiln_cache_sweep, %i[long long], :long, blocking: true
      ffi_func :kiln_cache_clear, [:long], :long, blocking: true
      ffi_func :kiln_cache_stats_read, [:long], :long, blocking: true
      ffi_func :kiln_cache_stat, [:long], :long
      ffi_func :kiln_cache_free, [:long], :long, blocking: true
    end

    STAT_NAMES = %i[entries bytes hits misses evictions expirations refusals].freeze
    MAX_SHARDS = 256
    MAX_KEY = 65_536
    MAX_VALUE = 1 << 30
    MAX_ENTRIES = 1 << 28
    MAX_TTL = 1 << 40
    BUSY = -3
    MAX_INTEGER = 9_223_372_036_854_775_807
    DEFAULT_VALUE = 1 << 20
    DEFAULT_SHARDS = 16
    SWEEP_BUDGET = 1024

    module Limits
      class << self
        def check(max_entries, max_bytes, max_value)
          unless positive?(max_entries) && max_entries <= MAX_ENTRIES
            raise ArgumentError, "max_entries must be an Integer from 1 to #{MAX_ENTRIES}"
          end
          unless positive?(max_bytes) && max_bytes <= MAX_INTEGER
            raise ArgumentError, 'max_bytes must be a positive C long Integer'
          end
          return if max_value.is_a?(Integer) && max_value.between?(0, MAX_VALUE)

          raise ArgumentError, "max_value must be an Integer from 0 to #{MAX_VALUE}"
        end

        def shards(requested, max_entries, max_bytes)
          unless requested.is_a?(Integer) && requested.between?(1, MAX_SHARDS) && requested.nobits?(requested - 1)
            raise ArgumentError, "shards must be a power of two from 1 to #{MAX_SHARDS}"
          end

          count = requested
          count /= 2 while count > 1 && (max_entries < count || max_bytes < count)
          count
        end

        def ttl_ms(ttl)
          return 0 if ttl.nil?

          raise ArgumentError, 'ttl must be a positive number of seconds or nil' unless valid_ttl?(ttl)
          return MAX_TTL * 1000 if ttl >= MAX_TTL

          millis = (ttl * 1000).ceil
          return 1 if millis < 1

          millis
        end

        private

        def positive?(value) = value.is_a?(Integer) && value.positive?

        def valid_ttl?(ttl)
          positive = ttl.is_a?(Integer) || (ttl.is_a?(Float) && ttl.finite?)
          positive && ttl.positive?
        end
      end
    end

    attr_reader :max_entries, :max_bytes, :max_value, :shards

    def initialize(max_entries:, max_bytes:, max_value: DEFAULT_VALUE, shards: DEFAULT_SHARDS)
      Limits.check(max_entries, max_bytes, max_value)
      @max_entries = max_entries
      @max_bytes = max_bytes
      @max_value = max_value
      @shards = Limits.shards(shards, max_entries, max_bytes)
      made = Native.kiln_cache_new(@shards, max_entries, max_bytes, max_value)
      raise ArgumentError, 'invalid cache limits' if made == -2
      raise NoMemoryError, 'cache could not be created (memory, or 64 open caches)' if made.negative?

      @handle = made
    end

    def get(key)
      text = key_text(key)
      value = Native.kiln_cache_get_try(@handle, text, text.bytesize)
      found = Native.kiln_cache_found
      if found == BUSY
        value = Native.kiln_cache_get(@handle, text, text.bytesize)
        found = Native.kiln_cache_found
      end
      return value if found == 1
      raise NoMemoryError, 'cache read buffer could not be allocated' if found == -2
      raise IOError, 'cache is closed' if found.negative?

      nil
    end

    def [](key) = get(key)

    def set(key, value, ttl: nil)
      raise TypeError, 'cache values must be Strings' unless value.is_a?(String)

      bytes = value.to_s
      text = key_text(key)
      opened(store(text, bytes, Limits.ttl_ms(ttl))) == 1
    end

    def []=(key, value)
      set(key, value)
    end

    def fetch(key, ttl: nil)
      cached = get(key)
      return cached unless cached.nil?

      fresh = yield
      set(key, fresh, ttl: ttl)
      fresh
    end

    def delete(key)
      text = key_text(key)
      opened(remove(text)) == 1
    end

    def sweep(budget = SWEEP_BUDGET)
      unless budget.is_a?(Integer) && budget.between?(0, MAX_INTEGER)
        raise ArgumentError, 'sweep budget must be a non-negative C long Integer'
      end

      opened(Native.kiln_cache_sweep(@handle, budget))
    end

    def clear = opened(Native.kiln_cache_clear(@handle))

    def stats
      opened(Native.kiln_cache_stats_read(@handle))
      { entries: Native.kiln_cache_stat(0), bytes: Native.kiln_cache_stat(1), hits: Native.kiln_cache_stat(2),
        misses: Native.kiln_cache_stat(3), evictions: Native.kiln_cache_stat(4),
        expirations: Native.kiln_cache_stat(5), refusals: Native.kiln_cache_stat(6) }
    end

    def close
      Native.kiln_cache_free(@handle)
      nil
    end

    def closed? = Native.kiln_cache_open(@handle).zero?

    private

    def store(text, bytes, millis)
      status = Native.kiln_cache_set_try(@handle, text, text.bytesize, bytes, bytes.bytesize, millis)
      return status unless status == BUSY

      Native.kiln_cache_set(@handle, text, text.bytesize, bytes, bytes.bytesize, millis)
    end

    def remove(text)
      status = Native.kiln_cache_delete_try(@handle, text, text.bytesize)
      return status unless status == BUSY

      Native.kiln_cache_delete(@handle, text, text.bytesize)
    end

    def opened(status)
      raise IOError, 'cache is closed' if status.negative?

      status
    end

    def key_text(key)
      text = key.to_s
      raise ArgumentError, "cache keys are at most #{MAX_KEY} bytes" if text.bytesize > MAX_KEY

      text
    end
  end
end
