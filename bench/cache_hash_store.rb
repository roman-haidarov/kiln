class CacheHashStore
  def initialize(limit, shards, copy: false)
    @shards = shards
    @limit = limit / shards
    @copy = copy
    @maps = Array.new(shards) { {} }
    @locks = Array.new(shards) { Mutex.new }
  end

  def get(key)
    index = key.hash & (@shards - 1)
    value = @locks[index].synchronize { @maps[index][key] }
    @copy && value ? value.dup : value
  end

  def put(key, value)
    index = key.hash & (@shards - 1)
    @locks[index].synchronize do
      map = @maps[index]
      map.shift if map.size >= @limit && !map.key?(key)
      map[key] = @copy ? value.dup : value
    end
  end

  def size
    total = 0
    index = 0
    while index < @shards
      total += @locks[index].synchronize { @maps[index].size }
      index += 1
    end
    total
  end

  def close = nil
end
