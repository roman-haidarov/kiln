module Kiln
  module Runtime
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

  end
end
