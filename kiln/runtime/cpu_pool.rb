require 'kiln/runtime/cpu_pool/workers'
require 'kiln/runtime/cpu_pool/shutdown'
require 'kiln/runtime/cpu_pool/jobs'

module Kiln
  module Runtime
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
