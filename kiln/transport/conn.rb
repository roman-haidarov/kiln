module Kiln
  module Transport
    class Inlet
      EMPTY = ''.b.freeze
      BAD_BODY = -400
      BIG_TRAILERS = -431
      TOO_LARGE = -413

      attr_reader :slot, :gen, :want

      module Signals
        def offer(data)
          @lock.synchronize do
            @chunk = data
            @wanted = false
            @cond.broadcast
          end
        end

        def finish
          @lock.synchronize do
            @eof = true
            @wanted = false
            @cond.broadcast
          end
        end

        def fail_with(code)
          @lock.synchronize do
            @error = code
            @wanted = false
            @cond.broadcast
          end
        end

        def nudge
          @lock.synchronize do
            @woken = true
            @cond.broadcast
          end
        end

        def halt
          @lock.synchronize do
            @halted = true
            @cond.broadcast
          end
        end
      end

      include Signals

      def initialize(server, slot, gen, read_timeout)
        @server = server
        @slot = slot
        @gen = gen
        @read_timeout = read_timeout
        @lock = Mutex.new
        @cond = ConditionVariable.new
        @want = HTTP::Payload::CHUNK
        reset_flags
      end

      def pull(max)
        limit = Kiln::Runtime.now + @read_timeout
        loop do
          chunk = await_chunk(max, pull_wait(limit - Kiln::Runtime.now))
          return chunk if chunk.nil? || !chunk.empty?
        end
      end

      def await_chunk(max, wait)
        @server.inlet_wanted(self) if request_chunk?(max)
        @lock.synchronize do
          wait_ready(Kiln::Runtime.now + wait)
          @woken = false
          hand_out(max)
        end
      end

      private

      def reset_flags
        @chunk = nil
        @eof = false
        @error = 0
        @wanted = false
        @halted = false
        @woken = false
      end

      def pull_wait(left)
        deadline = Kiln::Runtime.remaining
        raise Runtime::DeadlineExceeded, 'deadline exceeded' if deadline && deadline <= 0
        raise HTTP::RequestTimeout, 'request body timeout' if left <= 0

        deadline && deadline < left ? deadline : left
      end

      def request_chunk?(max)
        @lock.synchronize do
          @want = max
          if inlet_ready?
            false
          else
            first = !@wanted
            @wanted = true
            first
          end
        end
      end

      def wait_ready(limit)
        until inlet_ready? || @woken
          left = limit - Kiln::Runtime.now
          break if left <= 0

          @cond.wait(@lock, left)
        end
      end

      def inlet_ready? = !@chunk.nil? || @eof || @error != 0 || @halted

      def hand_out(max)
        chunk = @chunk
        return split_chunk(chunk, max) if chunk
        return nil if @eof

        raise_failure
        EMPTY
      end

      def split_chunk(chunk, max)
        if chunk.bytesize > max
          @chunk = chunk.byteslice(max, chunk.bytesize - max)
          return chunk.byteslice(0, max)
        end
        @chunk = nil
        chunk
      end

      def raise_failure
        raise HTTP::BadRequest, 'malformed request body' if @error == BAD_BODY
        raise HTTP::TrailersTooLarge, 'trailers too large' if @error == BIG_TRAILERS
        raise HTTP::PayloadTooLarge, 'payload too large' if @error == TOO_LARGE
        raise Runtime::ClientGone, 'client went away' if @error != 0 || @halted
      end
    end

    class Tunnel
      READ = 64 * 1024

      def initialize(inlet, outlet, write_timeout)
        @inlet = inlet
        @outlet = outlet
        @write_timeout = write_timeout
        @closed = false
      end

      def read(max = READ, timeout: nil)
        raise Runtime::ClientGone, 'connection closed' if @closed

        chunk = @inlet.await_chunk(max, timeout.nil? ? 3600.0 : timeout)
        return nil if chunk&.empty? && @outlet.closed?

        chunk
      end

      def write(bytes)
        raise Runtime::ClientGone, 'connection closed' if @closed

        data = bytes.to_s
        @outlet.enqueue(Inlet::EMPTY, data.b, Kiln::Runtime.now + @write_timeout) unless data.empty?
        self
      end

      def <<(bytes) = write(bytes)
      def flush = self

      def close
        @closed = true
        self
      end

      def closed? = @closed || @outlet.closed?
    end

    class SocketConn
      READ = 64 * 1024

      def initialize(sock, buffer, write, closed)
        @sock = sock
        @buffer = buffer
        @write = write
        @closed_probe = closed
        @closed = false
      end

      def read(max = READ, timeout: nil)
        raise Runtime::ClientGone, 'connection closed' if @closed
        return @buffer.take([@buffer.size, max].min) unless @buffer.empty?

        receive(max, timeout.nil? ? nil : Kiln::Runtime.now + timeout)
      rescue IOError, SystemCallError
        nil
      end

      def write(bytes)
        raise Runtime::ClientGone, 'connection closed' if @closed

        data = bytes.to_s
        raise Runtime::ClientGone, 'write failed' unless data.empty? || @write.call(data.b)

        self
      end

      def <<(bytes) = write(bytes)
      def flush = self

      def close
        @closed = true
        self
      end

      def closed? = @closed || @closed_probe.call == true

      private

      def receive(max, limit)
        fd = @sock.fileno
        loop do
          chunk = HTTP::Native.kiln_recv(fd, [max, 65_536].min)
          return chunk unless chunk.empty?
          return nil unless HTTP::Native.kiln_recv_status == -1 && !closed?

          left = limit.nil? ? 1.0 : limit - Kiln::Runtime.now
          return Inlet::EMPTY if left <= 0

          @sock.wait_readable([left, 1.0].min)
        end
      end
    end
  end
end
