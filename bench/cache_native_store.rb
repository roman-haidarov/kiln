class CacheNativeStore
  def initialize(limit, value_bytes, shards)
    @cache = Kiln::Cache.new(max_entries: limit, max_bytes: limit * (value_bytes + 192) * 2,
                             max_value: value_bytes + 128, shards: shards)
  end

  def get(key) = @cache.get(key)
  def put(key, value) = @cache.set(key, value)
  def size = @cache.stats[:entries]
  def close = @cache.close
end
