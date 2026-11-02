module Kiln
  class Server
    class DispatchBudget
      def initialize(requests, bytes)
        @max_requests = requests
        @max_bytes = bytes
        @uv = nil
        @shared = false
        @requests = 0
        @bytes = 0
        @lock = Mutex.new
      end

      def bind(uv, shared)
        @uv = uv
        @shared = shared
      end
      def detach = @uv = nil

      def reserve(job, bytes)
        if @shared
          return false unless @uv.kiln_uv_pending_reserve(@max_requests, @max_bytes, bytes) == 1
        else
          @lock.synchronize do
            return false if @requests >= @max_requests || bytes > @max_bytes - @bytes

            @requests += 1
            @bytes += bytes
          end
        end

        job.queue_bytes = bytes
        job.queued = true
        true
      end

      def release(job)
        if @shared
          return unless job.queued

          @uv.kiln_uv_pending_release(job.queue_bytes)
          job.queued = false
        else
          @lock.synchronize do
            return unless job.queued

            job.queued = false
            @requests -= 1
            @bytes -= job.queue_bytes
          end
        end
      end

      def requests
        return nil if @uv.nil?

        @shared ? @uv.kiln_uv_pending_requests : @lock.synchronize { @requests }
      end

      def bytes
        return nil if @uv.nil?

        @shared ? @uv.kiln_uv_pending_bytes : @lock.synchronize { @bytes }
      end
    end

    private_constant :DispatchBudget
  end
end
