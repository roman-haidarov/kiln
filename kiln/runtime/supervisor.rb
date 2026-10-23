module Kiln
  module Runtime
    class Supervisor
      MIN_DELAY = 0.1
      MAX_DELAY = 5.0
      STABLE = 10.0

      def initialize(log)
        @log = log
        @children = []
        @stopping = false
        @restarts = 0
        @lock = Mutex.new
      end

      def child(name, &body)
        @children << Thread.new do
          Thread.current.report_on_exception = false
          supervise_child(name, body)
        end
      end

      def restarts = @lock.synchronize { @restarts }

      def stop
        @stopping = true
        kill_children
        join_children
      end

      private

      def kill_children
        @children.each { |thread| thread.kill if thread.alive? }
      end

      def join_children
        @children.each { |thread| safe_join { thread.join(2) } }
      end

      def supervise_child(name, body)
        delay = MIN_DELAY
        until @stopping
          delay = run_child(name, body, delay)
          break if delay.negative?
        end
      end

      def run_child(name, body, delay)
        started = Kiln::Runtime.now
        body.call
        -1.0
      rescue *Kiln::Runtime::STOPS
        -1.0
      rescue *Kiln::Runtime::FAILURES => e
        return -1.0 if @stopping

        child_crashed(name, e, Kiln::Runtime.now - started > STABLE ? MIN_DELAY : delay)
      end

      def child_crashed(name, error, delay)
        @lock.synchronize { @restarts += 1 }
        safe_log(name, error, delay)
        Kernel.sleep delay unless @stopping
        [delay * 2, MAX_DELAY].min
      end

      def safe_join
        yield
      rescue *Kiln::Runtime::FAILURES
        nil
      end

      def safe_log(name, error, delay)
        @log.error("service #{name} crashed: #{error.class}: #{error.message}; restart in #{delay}s")
      rescue *Kiln::Runtime::FAILURES
        nil
      end
    end
  end
end
