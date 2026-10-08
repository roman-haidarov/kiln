module Kiln
  class CpuPool
    def initialize(n, queue: nil)
      raise ArgumentError, "cpu pool size" unless n.is_a?(Integer) && n > 0
      raise ArgumentError, "cpu pool queue" unless queue.nil? || (queue.is_a?(Integer) && queue > 0)

      @size = n
      @lock = Mutex.new
      @jobs = SizedQueue.new(queue || n * 8)

      @deaths, @ready, @retired = Queue.new, Queue.new, Queue.new
      @skipped, @overran, @busy, @alive, @respawned, @spawn_failures = 0, 0, 0, 0, 0, 0
      @stopping, @threads = {}, {}

      @overran_seconds = 0.0
      @booting = true
      @closed = false
      initialized = false
      begin
        n.times { spawn_one }
        n.times { raise WorkerLost, "cpu worker startup timeout" unless @ready.pop(timeout: 1.0) }

        @lock.synchronize { @booting = false }
        @supervisor = Thread.new do
          Thread.current.report_on_exception = false
          supervise
        end
        initialized = true
      ensure
        shutdown(grace: 0) unless initialized
      end
    end

    def run(timeout: 5.0, &fn)
      raise ArgumentError, "block required" unless fn
      unless (timeout.is_a?(Integer) || timeout.is_a?(Float)) && timeout.finite? && timeout > 0
        raise ArgumentError, "cpu pool timeout"
      end
      raise PoolTimeout, "cpu pool closed" if closed?
      started = Kiln.now
      expires = started + timeout
      deadline = Kiln.deadline
      by_deadline = deadline > 0 && deadline <= expires
      expires = deadline if by_deadline
      raise DeadlineExceeded, "deadline exceeded" if by_deadline && expires <= started
      reply = Queue.new
      job = [fn, reply, expires, deadline, Thread.current[:request_id], by_deadline]
      msg = self.submit_and_wait(job, reply, expires)
      if msg.nil?
        raise DeadlineExceeded, "deadline exceeded" if by_deadline
        raise PoolTimeout, closed? ? "cpu pool closed" : "cpu pool timeout"
      end
      kind, val = msg
      raise val if kind == :err
      val
    end

    def close
      @lock.synchronize { @closed = true }
      @jobs.close
      @deaths << false
      self
    end

    def await_workers(timeout = -1.0)
      unless (timeout.is_a?(Integer) || timeout.is_a?(Float)) && timeout.finite? && (timeout == -1 || timeout >= 0)
        raise ArgumentError, "cpu pool await timeout"
      end
      forever = timeout == -1
      limit = Kiln.now + timeout
      loop do
        threads = @lock.synchronize { retire; @threads.keys }
        live = threads.any? { |thread| thread.alive? }
        live = true if @supervisor && @supervisor.alive?
        break unless live
        return false unless forever || Kiln.now < limit
        Kernel.sleep 0.01
      end
      alive_workers == 0
    end

    def shutdown(grace: 5.0)
      unless (grace.is_a?(Integer) || grace.is_a?(Float)) && grace.finite? && grace >= 0
        raise ArgumentError, "cpu pool shutdown grace"
      end
      close
      return true if await_workers(grace)
      victims = @lock.synchronize do
        retire
        pending = []
        @threads.each_key do |thread|
          unless @stopping.key?(thread)
            @stopping[thread] = true
            pending << thread
          end
        end
        pending
      end
      victims.each { |thread| thread.kill if thread.alive? }
      until @jobs.empty?
        job = @jobs.pop
        job[1] << [:err, WorkerLost.new("cpu pool shutdown")] if job
      end
      await_workers(1.0)
    end

    def closed? = @closed
    def size = @size
    def skipped = @lock.synchronize { @skipped }
    def overran = @lock.synchronize { @overran }
    def overran_seconds = @lock.synchronize { @overran_seconds }
    def busy = @lock.synchronize { retire; @busy }
    def alive_workers = @lock.synchronize { retire; @alive }
    def respawned = @lock.synchronize { @respawned }
    def spawn_failures = @lock.synchronize { @spawn_failures }
    def queued = @jobs.size

    private

    def submit_and_wait(job, reply, expires)
      queued = begin
        @jobs.push(job, true)
        true
      rescue ThreadError, ClosedQueueError
        false
      end

      unless queued || closed?
        rest = expires - Kiln.now
        queued = begin
          rest > 0 && @jobs.push(job, timeout: rest) && Kiln.now < expires
        rescue ClosedQueueError
          false
        end
      end
      if queued
        rest = expires - Kiln.now
        reply.pop(timeout: rest) if rest > 0
      end
    end

    def spawn_one
      @lock.synchronize do
        return false if @closed
        boot = @booting
        thread = Thread.new do
          Thread.current.report_on_exception = false
          worker_main(boot)
        end
        @threads[thread] = true
        @alive += 1
      end
      true
    end

    def retire
      until @retired.empty?
        thread, was_busy = @retired.pop
        if @threads.delete(thread)
          @alive -= 1
          @busy -= 1 if was_busy
          @stopping.delete(thread)
        end
      end
      true
    end

    def supervise
      while @deaths.pop
        delay = 0.01
        until closed?
          ok = begin
                 spawn_one
               rescue StandardError
                 false
               end
          break if closed?
          if ok
            @lock.synchronize { retire; @respawned += 1 }
            break
          end
          @lock.synchronize { @spawn_failures += 1 }
          Kernel.sleep delay
          delay = delay * 2 > 1.0 ? 1.0 : delay * 2
        end
      end
      true
    end

    def worker_main(boot)
      clean = false
      begin
        @ready << true if boot
        work_loop
        clean = true
      ensure
        orphan = Thread.current[:kiln_cpu_reply]
        if orphan
          Thread.current[:kiln_cpu_reply] = nil
          orphan << [:err, WorkerLost.new("cpu worker lost")]
        end
        @retired << [Thread.current, Thread.current[:kiln_cpu_busy]]
        @deaths << true unless clean || @closed
      end
    end

    def work_loop
      while (job = @jobs.pop)
        Thread.current[:kiln_cpu_reply] = job[1]
        fn, reply, expires, dl, rid, by_deadline = job
        started = @lock.synchronize do
          if Kiln.now >= expires
            @skipped += 1
            false
          else
            @busy += 1
            Thread.current[:kiln_cpu_busy] = true
            true
          end
        end
        unless started
          reply << [:err, by_deadline ? DeadlineExceeded.new("deadline exceeded") : PoolTimeout.new("cpu pool timeout")]
          Thread.current[:kiln_cpu_reply] = nil
          next
        end
        Thread.current[:kiln_deadline] = dl
        Thread.current[:request_id] = rid
        fatal = nil
        msg = begin
                [:ok, fn.call]
              rescue Exception => e
                fatal = e if Kiln.unwind?(e)
                [:err, fatal ? WorkerLost.new("cpu worker terminated by #{e.class}") : e]
              end
        finished = Kiln.now
        @lock.synchronize do
          @busy -= 1
          Thread.current[:kiln_cpu_busy] = false
          if finished > expires
            @overran += 1
            @overran_seconds += finished - expires
          end
        end
        Thread.current[:kiln_deadline] = nil
        Thread.current[:request_id] = nil
        reply << msg
        Thread.current[:kiln_cpu_reply] = nil
        raise fatal if fatal
      end
      true
    end
  end
end
