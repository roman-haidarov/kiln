module Kiln
  class CpuPool
    include Check

    def initialize(count, queue: nil)
      check_rules([['cpu pool size', count, :int_at_least_one]])
      check_rules([['cpu pool queue', queue, :int_at_least_one]]) unless queue.nil?

      @size = count
      @lock = Mutex.new
      @jobs = SizedQueue.new(queue || (count * 8))

      @deaths = Queue.new
      @ready = Queue.new
      @retired = Queue.new
      @skipped = 0
      @overran = 0
      @busy = 0
      @alive = 0
      @respawned = 0
      @spawn_failures = 0
      @stopping = {}
      @threads = {}

      @overran_seconds = 0.0
      @booting = true
      @closed = false
      initialized = false
      begin
        count.times { spawn_one? }
        count.times { raise WorkerLost, 'cpu worker startup timeout' unless @ready.pop(timeout: 1.0) }

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

    def run(timeout: 5.0, &work)
      raise ArgumentError, 'block required' unless work

      check_rules([['cpu pool timeout', timeout, :seconds_above]])
      raise PoolTimeout, 'cpu pool closed' if closed?

      started = Kiln.now
      expires = started + timeout
      deadline = Kiln.deadline
      by_deadline = deadline.positive? && deadline <= expires
      expires = deadline if by_deadline
      raise DeadlineExceeded, 'deadline exceeded' if by_deadline && expires <= started

      reply = Queue.new
      job = [work, reply, expires, deadline, Thread.current[:request_id], by_deadline]
      msg = self.submit_and_wait(job, reply, expires)
      if msg.nil?
        raise DeadlineExceeded, 'deadline exceeded' if by_deadline

        raise PoolTimeout, closed? ? 'cpu pool closed' : 'cpu pool timeout'
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
      check_rules([['cpu pool await timeout', timeout, :await_timeout]])
      forever = timeout == -1
      limit = Kiln.now + timeout
      loop do
        threads = @lock.synchronize do
          retire
          @threads.keys
        end
        live = threads.any?(&:alive?)
        live = true if @supervisor&.alive?
        break unless live
        return false unless forever || Kiln.now < limit

        Kernel.sleep 0.01
      end
      alive_workers.zero?
    end

    def shutdown(grace: 5.0)
      check_rules([['cpu pool shutdown grace', grace, :seconds_at_least]])
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
        job[1] << [:err, WorkerLost.new('cpu pool shutdown')] if job
      end
      await_workers(1.0)
    end

    attr_reader :size

    def closed? = @closed
    def skipped = @lock.synchronize { @skipped }
    def overran = @lock.synchronize { @overran }
    def overran_seconds = @lock.synchronize { @overran_seconds }

    def busy
      @lock.synchronize do
        retire
        @busy
      end
    end

    def alive_workers
      @lock.synchronize do
        retire
        @alive
      end
    end

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
          rest.positive? && @jobs.push(job, timeout: rest) && Kiln.now < expires
        rescue ClosedQueueError
          false
        end
      end
      return unless queued

      rest = expires - Kiln.now
      reply.pop(timeout: rest) if rest.positive?
    end

    def spawn_one?
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
    end

    def supervise
      while @deaths.pop
        delay = 0.01
        until closed?
          ok = begin
            spawn_one?
          rescue StandardError
            false
          end
          break if closed?

          if ok
            @lock.synchronize do
              retire
              @respawned += 1
            end
            break
          end
          @lock.synchronize { @spawn_failures += 1 }
          Kernel.sleep delay
          delay = delay * 2 > 1.0 ? 1.0 : delay * 2
        end
      end
    end

    def worker_main(boot)
      current = Thread.current
      clean = false
      begin
        @ready << true if boot
        work_loop
        clean = true
      ensure
        orphan = current[:kiln_cpu_reply]
        if orphan
          current[:kiln_cpu_reply] = nil
          orphan << [:err, WorkerLost.new('cpu worker lost')]
        end
        @retired << [current, current[:kiln_cpu_busy]]
        @deaths << true unless clean || @closed
      end
    end

    def work_loop
      while (job = @jobs.pop)
        run_job(job)
      end
    end

    def run_job(job)
      current = Thread.current
      work, reply, expires, deadline_at, request_id, by_deadline = job
      current[:kiln_cpu_reply] = reply
      started = @lock.synchronize do
        if Kiln.now >= expires
          @skipped += 1
          false
        else
          @busy += 1
          current[:kiln_cpu_busy] = true
          true
        end
      end
      unless started
        reply << [:err, by_deadline ? DeadlineExceeded.new('deadline exceeded') : PoolTimeout.new('cpu pool timeout')]
        current[:kiln_cpu_reply] = nil
        return nil
      end
      current[:kiln_deadline] = deadline_at
      current[:request_id] = request_id
      fatal = nil
      msg = begin
        [:ok, work.call]
      rescue Exception => err
        fatal = err if Kiln.unwind?(err)
        [:err, fatal ? WorkerLost.new("cpu worker terminated by #{err.class}") : err]
      end
      finished = Kiln.now
      @lock.synchronize do
        @busy -= 1
        current[:kiln_cpu_busy] = false
        if finished > expires
          @overran += 1
          @overran_seconds += finished - expires
        end
      end
      current[:kiln_deadline] = nil
      current[:request_id] = nil
      reply << msg
      current[:kiln_cpu_reply] = nil
      raise fatal if fatal

      nil
    end
  end
end
