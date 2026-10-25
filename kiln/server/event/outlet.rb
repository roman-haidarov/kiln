module Kiln
  class Server
    class Outlet
      HIGH_WATER = 256 * 1024

      module State
        private

        def init_queue
          @pending = [''.b].drop(1)
          @queued = 0
          @backlog = 0
          @deferred = nil
          @ending = HTTP::Stream::TERMINATOR
        end

        def init_flags
          @gone = false
          @finished = false
          @failed = false
          @flagged = false
          @thread = nil
          @tunnel = false
        end
      end

      include State

      attr_reader :slot, :gen, :keep, :chunked, :deferred
      attr_accessor :thread, :ending, :tunnel

      def initialize(server, slot, gen, keep, chunked)
        @server = server
        @slot = slot
        @gen = gen
        @keep = keep
        @chunked = chunked
        @lock = Mutex.new
        @cond = ConditionVariable.new
        init_queue
        init_flags
      end

      def enqueue(prefix, bytes, limit)
        signal = @lock.synchronize do
          raise Runtime::ClientGone, 'client went away' if @gone

          @pending << prefix unless prefix.empty?
          @pending << bytes
          @queued += prefix.bytesize + bytes.bytesize
          raise_flag
        end
        @server.stream_ready(self) if signal
        @lock.synchronize { hold(limit) }
      end

      def complete(failed)
        signal = @lock.synchronize do
          @finished = true
          @failed = failed
          raise_flag
        end
        @server.stream_ready(self) if signal
      end

      def drain_pending
        @lock.synchronize do
          pieces = @pending
          @pending = [''.b].drop(1)
          @queued = 0
          @flagged = false
          [pieces, @finished, @failed]
        end
      end

      def record_backlog(left)
        @lock.synchronize do
          if left.negative?
            @gone = true
          else
            @backlog = left
          end
          @cond.broadcast
        end
      end

      def hold_back(ctx)
        list = @deferred
        if list
          list << ctx
        else
          @deferred = [ctx]
        end
        0
      end

      def halt
        @lock.synchronize do
          @gone = true
          @cond.broadcast
        end
        thread = @thread
        thread.kill if thread&.alive?
      end

      def gone? = @gone
      def closed? = @gone || @server.draining?

      private

      def raise_flag
        return false if @flagged

        @flagged = true
      end

      def hold(limit)
        until @gone || @backlog + @queued <= HIGH_WATER
          left = limit - Kiln::Runtime.now
          if left <= 0
            @gone = true
            break
          end
          @cond.wait(@lock, left)
        end
        raise Runtime::ClientGone, 'client went away' if @gone
      end
    end

  end
end
