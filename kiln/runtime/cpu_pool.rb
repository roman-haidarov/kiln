module Kiln
  module Runtime
    module CpuPoolWorkers
      def spawn_one?
        @lock.synchronize do
          return false if @closed

          @threads[launch_worker(@booting)] = true
          @alive += 1
        end
        true
      end

      private

      def start_workers(count)
        initialized = false
        begin
          boot_workers(count)
          start_supervisor
          initialized = true
        ensure
          shutdown(grace: 0) unless initialized
        end
      end

      def boot_workers(count)
        count.times { spawn_one? }
        count.times { raise WorkerLost, 'cpu worker startup timeout' unless @ready.pop(timeout: 1.0) }
        @lock.synchronize { @booting = false }
      end

      def start_supervisor
        @supervisor = Thread.new do
          Thread.current.report_on_exception = false
          supervise
        end
      end

      def launch_worker(boot)
        Thread.new do
          Thread.current.report_on_exception = false
          worker_main(boot)
        end
      end

      def retire
        until @retired.empty?
          thread, was_busy = @retired.pop
          next unless @threads.delete(thread)

          @alive -= 1
          @busy -= 1 if was_busy
          @stopping.delete(thread)
        end
      end

      def supervise
        respawn while @deaths.pop
      end

      def respawn
        delay = 0.01
        until closed?
          spawned = try_spawn
          break if closed?
          return note_respawn if spawned

          @lock.synchronize { @spawn_failures += 1 }
          Kernel.sleep delay
          delay = [delay * 2, 1.0].min
        end
      end

      def try_spawn
        spawn_one?
      rescue StandardError
        false
      end

      def note_respawn
        @lock.synchronize do
          retire
          @respawned += 1
        end
        nil
      end

      def worker_main(boot)
        clean = false
        begin
          @ready << true if boot
          work_loop
          clean = true
        ensure
          worker_exit(Thread.current, clean)
        end
      end

      def worker_exit(current, clean)
        orphan = current[:kiln_cpu_reply]
        if orphan
          current[:kiln_cpu_reply] = nil
          orphan << [:err, WorkerLost.new('cpu worker lost')]
        end
        @retired << [current, current[:kiln_cpu_busy]]
        @deaths << true unless clean || @closed
      end

      def work_loop
        while (job = @jobs.pop)
          run_job(job)
        end
      end
    end

    module CpuPoolShutdown
      private

      def stop_victims
        victims = @lock.synchronize do
          retire
          unstopped_threads
        end
        victims.each { |thread| thread.kill if thread.alive? }
      end

      def unstopped_threads
        pending = []
        @threads.each_key do |thread|
          next if @stopping.key?(thread)

          @stopping[thread] = true
          pending << thread
        end
        pending
      end

      def workers_running?
        threads = @lock.synchronize do
          retire
          @threads.keys
        end
        threads.any?(&:alive?) || @supervisor&.alive? == true
      end
    end

    module CpuPoolJobs
      Job = Struct.new(:work, :reply, :expires, :deadline, :request_id, :by_deadline)

      private

      def new_job(work, timeout)
        started = Kiln::Runtime.now
        expires = started + timeout
        deadline = Kiln::Runtime.deadline
        by_deadline = deadline.positive? && deadline <= expires
        expires = deadline if by_deadline
        raise DeadlineExceeded, 'deadline exceeded' if by_deadline && expires <= started

        Job.new(work, Queue.new, expires, deadline, Thread.current[:request_id], by_deadline)
      end

      def raise_unsent(job)
        raise DeadlineExceeded, 'deadline exceeded' if job.by_deadline

        raise PoolTimeout, closed? ? 'cpu pool closed' : 'cpu pool timeout'
      end

      def submit_and_wait(job)
        return unless enqueue?(job)

        rest = job.expires - Kiln::Runtime.now
        job.reply.pop(timeout: rest) if rest.positive?
      end

      def enqueue?(job)
        return true if push_now?(job)
        return false if closed?

        push_until?(job)
      end

      def push_now?(job)
        @jobs.push(job, true)
        true
      rescue ThreadError, ClosedQueueError
        false
      end

      def push_until?(job)
        rest = job.expires - Kiln::Runtime.now
        rest.positive? && @jobs.push(job, timeout: rest) && Kiln::Runtime.now < job.expires
      rescue ClosedQueueError
        false
      end

      def run_job(job)
        current = Thread.current
        current[:kiln_cpu_reply] = job.reply
        return skip_job(job, current) unless start_job?(job, current)

        msg, fatal = perform(job, current)
        finish_job(job, current)
        job.reply << msg
        current[:kiln_cpu_reply] = nil
        raise fatal if fatal

        nil
      end

      def start_job?(job, current)
        @lock.synchronize do
          if Kiln::Runtime.now >= job.expires
            @skipped += 1
            false
          else
            @busy += 1
            current[:kiln_cpu_busy] = true
            true
          end
        end
      end

      def skip_job(job, current)
        error = job.by_deadline ? DeadlineExceeded.new('deadline exceeded') : PoolTimeout.new('cpu pool timeout')
        job.reply << [:err, error]
        current[:kiln_cpu_reply] = nil
        nil
      end

      def perform(job, current)
        current[:kiln_deadline] = job.deadline
        current[:request_id] = job.request_id
        [[:ok, job.work.call], nil]
      rescue *Kiln::Runtime::FAILURES => e
        [[:err, e], nil]
      rescue *Kiln::Runtime::STOPS => e
        [[:err, WorkerLost.new("cpu worker terminated by #{e.class}")], e]
      end

      def finish_job(job, current)
        finished = Kiln::Runtime.now
        @lock.synchronize do
          @busy -= 1
          current[:kiln_cpu_busy] = false
          note_overrun(finished - job.expires) if finished > job.expires
        end
        current[:kiln_deadline] = nil
        current[:request_id] = nil
      end

      def note_overrun(seconds)
        @overran += 1
        @overran_seconds += seconds
      end

      def fail_queued
        until @jobs.empty?
          job = @jobs.pop
          job.reply << [:err, WorkerLost.new('cpu pool shutdown')] if job
        end
      end
    end

    class CpuPool
      include Check
      include CpuPoolWorkers
      include CpuPoolJobs
      include CpuPoolShutdown

      attr_reader :size

      def initialize(count, queue: nil)
        check_rules([['cpu pool size', count, :int_at_least_one]])
        check_rules([['cpu pool queue', queue, :int_at_least_one]]) unless queue.nil?

        @size = count
        @lock = Mutex.new
        @jobs = SizedQueue.new(queue || (count * 8))
        init_queues
        init_counters
        start_workers(count)
      end

      def run(timeout: 5.0, &work)
        raise ArgumentError, 'block required' unless work

        check_rules([['cpu pool timeout', timeout, :seconds_above]])
        raise PoolTimeout, 'cpu pool closed' if closed?

        job = new_job(work, timeout)
        msg = submit_and_wait(job)
        raise_unsent(job) if msg.nil?
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

      def wait_stopped?(timeout = -1.0)
        check_rules([['cpu pool await timeout', timeout, :await_timeout]])
        forever = timeout == -1
        limit = Kiln::Runtime.now + timeout
        while workers_running?
          return false unless forever || Kiln::Runtime.now < limit

          Kernel.sleep 0.01
        end
        alive_workers.zero?
      end

      def shutdown(grace: 5.0)
        check_rules([['cpu pool shutdown grace', grace, :seconds_at_least]])
        close
        return 0 if wait_stopped?(grace)

        stop_victims
        fail_queued
        wait_stopped?(1.0)
        alive_workers
      end

      def closed? = @closed
      def skipped = @lock.synchronize { @skipped }
      def overran = @lock.synchronize { @overran }
      def overran_seconds = @lock.synchronize { @overran_seconds }
      def respawned = @lock.synchronize { @respawned }
      def spawn_failures = @lock.synchronize { @spawn_failures }
      def queued = @jobs.size

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

      private

      def init_queues
        @deaths = Queue.new
        @ready = Queue.new
        @retired = Queue.new
        @stopping = {}
        @threads = {}
        @booting = true
        @closed = false
      end

      def init_counters
        @skipped = 0
        @overran = 0
        @busy = 0
        @alive = 0
        @respawned = 0
        @spawn_failures = 0
        @overran_seconds = 0.0
      end
    end
  end
end
