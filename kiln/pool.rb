module Kiln
  # Пул ресурсов (соединения к БД и т.п.). Ожидание свободного — паркует тред.
  class Pool
    def initialize(size, &factory)
      @size = size
      @q = SizedQueue.new(size)
      size.times { @q << factory.call }
    end

    def with(timeout: 1.0)
      c = @q.pop(timeout: timeout)
      raise PoolTimeout, "pool timeout" unless c
      begin
        yield c
      ensure
        @q << c            # ensure без rescue в этом кадре — срабатывает и при kill
      end
    end

    def available = @q.size
    def size = @size
  end

  # Пул для CPU-тяжёлой работы: Spinel не вытесняет рекурсию и долгие
  # встроенные методы, поэтому такая работа не должна жить в тредах запросов.
  class CpuPool
    def initialize(n)
      @jobs = Queue.new
      @workers = n.times.map do
        Thread.new do
          while (job = @jobs.pop)
            fn, reply = job
            r = begin
                  fn.call
                rescue => e
                  e
                end
            reply << r
          end
        end
      end
    end

    def run(&fn)
      reply = Queue.new
      @jobs << [fn, reply]
      r = reply.pop
      raise r if r.is_a?(Exception)
      r
    end
  end
end
