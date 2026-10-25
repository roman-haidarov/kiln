module Kiln
  module Runtime
    module PoolShutdown
      def shutdown(timeout: 5.0)
        raise ArgumentError, 'shutdown timeout' unless timeout.is_a?(Numeric) && timeout >= 0

        begin_shutdown
        deadline = Kiln::Runtime.now + timeout
        loop do
          flush_shutdown
          left = shutdown_left
          return left if left.zero? || Kiln::Runtime.now >= deadline

          Kernel.sleep(0.01)
        end
      end

      private

      def begin_shutdown
        @lock.synchronize { @state = :closing if @state == :open }
        wake_idle
      end

      def shutdown_left
        @lock.synchronize do
          drain_returns
          @state = :closed if @open.zero?
          @open
        end
      end

      def flush_shutdown
        loop do
          entry = next_shutdown_entry
          break unless entry

          finish_shutdown_entry(closed_cleanly?(entry))
        end
      end

      def next_shutdown_entry
        @lock.synchronize do
          drain_returns
          queue_idle_for_shutdown if @state != :open
          @shutdown_queue.shift
        end
      end

      def queue_idle_for_shutdown
        until @idle.empty?
          @shutdown_queue << @idle.pop
          @closing += 1
        end
      end

      def finish_shutdown_entry(success)
        @lock.synchronize do
          @closing -= 1
          if success
            @open -= 1
          else
            note_quarantine(nil)
            @close_failures += 1
          end
        end
      end
    end

  end
end
