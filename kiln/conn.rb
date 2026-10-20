module Kiln
  class Inlet
    EMPTY = ''.b.freeze
    BAD_BODY = -400
    BIG_TRAILERS = -431
    TOO_LARGE = -413

    attr_reader :slot, :gen, :want

    def initialize(server, slot, gen, read_timeout)
      @server = server
      @slot = slot
      @gen = gen
      @read_timeout = read_timeout
      @lock = Mutex.new
      @cond = ConditionVariable.new
      @chunk = nil
      @eof = false
      @error = 0
      @wanted = false
      @halted = false
      @woken = false
      @want = Payload::CHUNK
    end

    def pull(max)
      limit = Kiln.now + @read_timeout
      loop do
        now = Kiln.now
        left = limit - now
        deadline = Kiln.remaining
        raise DeadlineExceeded, 'deadline exceeded' if deadline && deadline <= 0
        raise RequestTimeout, 'request body timeout' if left <= 0

        chunk = await_chunk(max, deadline && deadline < left ? deadline : left)
        return chunk if chunk.nil? || !chunk.empty?
      end
    end

    def await_chunk(max, wait)
      ask = @lock.synchronize do
        @want = max
        if inlet_ready?
          false
        else
          first = !@wanted
          @wanted = true
          first
        end
      end
      @server.inlet_wanted(self) if ask
      @lock.synchronize do
        limit = Kiln.now + wait
        until inlet_ready? || @woken
          left = limit - Kiln.now
          break if left <= 0

          @cond.wait(@lock, left)
        end
        @woken = false
        hand_out(max)
      end
    end

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

    private

    def inlet_ready? = !@chunk.nil? || @eof || @error != 0 || @halted

    def hand_out(max)
      chunk = @chunk
      if chunk
        if chunk.bytesize > max
          @chunk = chunk.byteslice(max, chunk.bytesize - max)
          return chunk.byteslice(0, max)
        end
        @chunk = nil
        return chunk
      end
      return nil if @eof
      raise BadRequest, 'malformed request body' if @error == BAD_BODY
      raise TrailersTooLarge, 'trailers too large' if @error == BIG_TRAILERS
      raise PayloadTooLarge, 'payload too large' if @error == TOO_LARGE
      raise ClientGone, 'client went away' if @error != 0 || @halted

      EMPTY
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
      raise ClientGone, 'connection closed' if @closed

      chunk = @inlet.await_chunk(max, timeout.nil? ? 3600.0 : timeout)
      return nil if chunk&.empty? && @outlet.closed?

      chunk
    end

    def write(bytes)
      raise ClientGone, 'connection closed' if @closed

      data = bytes.to_s
      @outlet.enqueue(Inlet::EMPTY, data.b, Kiln.now + @write_timeout) unless data.empty?
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
      raise ClientGone, 'connection closed' if @closed

      unless @buffer.empty?
        take = @buffer.size < max ? @buffer.size : max
        return @buffer.take(take)
      end
      fd = @sock.fileno
      limit = timeout.nil? ? nil : Kiln.now + timeout
      loop do
        chunk = HttpNative.kiln_recv(fd, max > 65_536 ? 65_536 : max)
        return chunk unless chunk.empty?
        return nil unless HttpNative.kiln_recv_status == -1

        return nil if closed?

        left = limit.nil? ? 1.0 : limit - Kiln.now
        return Inlet::EMPTY if left <= 0

        IO.select([@sock], nil, nil, left > 1.0 ? 1.0 : left)
      end
    rescue IOError, SystemCallError
      nil
    end

    def write(bytes)
      raise ClientGone, 'connection closed' if @closed

      data = bytes.to_s
      raise ClientGone, 'write failed' unless data.empty? || @write.call(data.b)

      self
    end

    def <<(bytes) = write(bytes)
    def flush = self

    def close
      @closed = true
      self
    end

    def closed? = @closed || @closed_probe.call == true
  end
end
