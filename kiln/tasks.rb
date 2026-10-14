module Kiln
  class Token
    def initialize
      @lock = Mutex.new
      @cond = ConditionVariable.new
      @cancelled = false
    end

    def cancel
      @lock.synchronize do
        @cancelled = true
        @cond.broadcast
      end
      self
    end

    def cancelled? = @cancelled

    def wait(sec)
      limit = Kiln.now + sec
      @lock.synchronize do
        until @cancelled
          left = limit - Kiln.now
          break if left <= 0

          @cond.wait(@lock, left)
        end
        @cancelled
      end
    end
  end

  class Tasks
    attr_reader :token

    def initialize(log)
      @log = log
      @token = Token.new
      @lock = Mutex.new
      @threads = []
      @closed = false
    end

    def spawn(name, &work)
      raise ArgumentError, 'task needs a block' unless work

      @lock.synchronize do
        raise ArgumentError, 'tasks are shut down' if @closed

        compact_dead
        thread = Thread.new { run_task(name, work) }
        @threads << thread
        thread
      end
    end

    def every(name, interval, &work)
      raise ArgumentError, 'interval must be positive' unless interval.is_a?(Numeric) && interval.positive?
      raise ArgumentError, 'task needs a block' unless work

      spawn(name) { |token| tick(name, interval.to_f, token, work) }
    end

    def size = @lock.synchronize { compact_dead }

    def shutdown(grace: 5.0)
      raise ArgumentError, 'grace must be a non-negative number' unless grace.is_a?(Numeric) && grace >= 0

      threads = @lock.synchronize do
        @closed = true
        alive = live_threads
        @threads = []
        alive
      end
      @token.cancel
      reap(threads, Kiln.now + grace)
    end

    private

    def run_task(name, work)
      guarded(name) { work.call(@token) }
    end

    def tick(name, interval, token, work)
      due = Kiln.now + interval
      until token.wait(due - Kiln.now)
        guarded(name) { work.call(token) }
        due = next_due(due, interval)
      end
    end

    def guarded(name)
      yield
    rescue StandardError => error
      @log.error("task #{name}: #{error.class}: #{error.message}")
    end

    def next_due(due, interval)
      due += interval
      now = Kiln.now
      return due if due > now

      due + ((((now - due) / interval).floor + 1) * interval)
    end

    def compact_dead
      @threads = live_threads
      @threads.size
    end

    def live_threads
      collect_alive(@threads)
    end

    def collect_alive(threads)
      alive = []
      index = 0
      while index < threads.size
        thread = threads[index]
        alive << thread if thread.alive?
        index += 1
      end
      alive
    end

    def reap(threads, limit)
      Kernel.sleep 0.005 while threads.any?(&:alive?) && Kiln.now < limit
      stuck = collect_alive(threads)
      stuck.each(&:kill)
      settle(stuck, Kiln.now + 1.0)
      stuck.size
    end

    def settle(threads, limit)
      Kernel.sleep 0.001 while threads.any?(&:alive?) && Kiln.now < limit
    end
  end
end
