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

  end
end
