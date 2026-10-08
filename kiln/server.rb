module Kiln
  class Server
    MAX_HEADER = 16 * 1024
    WRITE_WINDOW = 256 * 1024
    INLINE_BODY = 16 * 1024
    NEVER = 1.0e18
    TIMEOUT_RESPONSE = "HTTP/1.1 504 Gateway Timeout\r\nContent-Type: text/plain\r\nContent-Length: 18\r\nConnection: close\r\n\r\ndeadline exceeded\n".b.freeze
    EMPTY_BODY = "".b.freeze
    LINGER = 0.5
    LINGER_BYTES = 256 * 1024
    ACCEPT_BACKOFF_MIN = 0.005
    ACCEPT_BACKOFF_MAX = 1.0
    CRLF = HttpSyntax::CRLF
    HEADER_END = "\r\n\r\n".b.freeze
    CONTINUE = "HTTP/1.1 100 Continue\r\n\r\n".b.freeze

    Slot = Struct.new(:thread, :sock, :deadline, :state, :done, :flying, :hidx, :outbox)

    class Outbox
      MAX_COUNT = 16
      MAX_BYTES = 64 * 1024

      attr_reader :data

      def initialize
        @data = (+"").b
        @count = 0
        @more = false
      end

      def mark(more)
        @more = more
      end

      def more? = @more
      def empty? = @data.empty?
      def fits?(size) = @more && @count < MAX_COUNT && @data.bytesize + size <= MAX_BYTES

      def push(wire)
        @data << wire
        @count += 1
      end

      def reset
        @data.clear
        @count = 0
      end
    end

    def initialize(handler, app, log:, port:, host: "0.0.0.0", max_conns: 10_000,
                   read_timeout: 5.0, request_timeout: 2.0, write_timeout: 10.0,
                   kill_grace: 1.0, max_body: 1 << 20, coop_budget: 4)
      @handler, @app, @log, @port, @host = handler, app, log, port, host
      @read_timeout, @request_timeout, @write_timeout = read_timeout, request_timeout, write_timeout
      @kill_grace, @max_body = kill_grace, max_body
      raise ArgumentError, "cooperative budget" unless coop_budget.is_a?(Integer) && coop_budget >= 0
      raise ArgumentError, "max_conns" unless max_conns.is_a?(Integer) && max_conns > 0
      raise ArgumentError, "max_body" unless max_body.is_a?(Integer) && max_body >= 0
      raise ArgumentError, "read_timeout" unless positive_seconds?(read_timeout)
      raise ArgumentError, "request_timeout" unless positive_seconds?(request_timeout)
      raise ArgumentError, "write_timeout" unless positive_seconds?(write_timeout)
      raise ArgumentError, "kill_grace" unless (kill_grace.is_a?(Integer) || kill_grace.is_a?(Float)) && kill_grace.finite? && kill_grace >= 0
      @coop_budget = coop_budget
      @slots = SizedQueue.new(max_conns)
      max_conns.times { @slots << true }
      @lock = Mutex.new
      @conns = {}
      @handling = []
      @reap_target = NEVER
      @in_flight = 0
      @seq = 0
      @killed = 0
      @late = 0
      @draining = false
      @shut = false
      @listener = nil
      @acceptor = nil
      @reaper = nil
    end

    def start
      raise Errno::EADDRINUSE if @acceptor&.alive? || @reaper&.alive? || connections > 0
      @draining = false
      @shut = false
      @listener = TCPServer.new(@host, @port)
      @finished = Queue.new
      @reap_wake = SizedQueue.new(1)
      @acceptor = Thread.new do
        Thread.current.report_on_exception = false
        accept_loop
      end
      @reaper = Thread.new do
        Thread.current.report_on_exception = false
        reap_loop
      end
      self
    end

    def port = @listener ? @listener.addr[1] : @port

    def shutdown(grace: 5.0)
      unless (grace.is_a?(Integer) || grace.is_a?(Float)) && grace.finite? && grace >= 0
        raise ArgumentError, "shutdown grace"
      end
      return in_flight if @shut
      return 0 unless @acceptor || @listener
      @lock.synchronize { @draining = true }
      close_quietly(@listener)
      stop_thread(@acceptor)
      deadline = Kiln.now + grace
      Kernel.sleep 0.01 while in_flight > 0 && Kiln.now < deadline
      left = in_flight
      @lock.synchronize { @shut = true }
      signal_reaper
      slots = @lock.synchronize { @conns.values }
      slots.each { |slot| abandon(slot) }
      slots.each { |slot| quiet_join(slot.thread) if slot.thread }
      quiet_join(@reaper)
      left
    end

    def abandon(slot)
      kill = @lock.synchronize do
        if slot.done
          false
        elsif slot.state == :writing
          release_socket(slot)
          false
        elsif slot.state != :handling
          stop_reading(slot)
          false
        else
          unless slot.outbox.empty?
            begin
              slot.sock.write_nonblock(slot.outbox.data, exception: false)
            rescue IOError, SystemCallError
              nil
            end
          end
          release_socket(slot)
          slot.state = :reaping
          true
        end
      end
      slot.thread.kill if kill && slot.thread&.alive?
      true
    end

    def positive_seconds?(value) = (value.is_a?(Integer) || value.is_a?(Float)) && value.finite? && value > 0

    def stop_thread(thread)
      return unless thread
      quiet_join(thread)
      return unless thread.alive?
      thread.kill
      quiet_join(thread)
    rescue Exception
      nil
    end

    def in_flight = @lock.synchronize { @in_flight }
    def connections = @lock.synchronize { @conns.size }
    def killed = @lock.synchronize { @killed }
    def late = @lock.synchronize { @late }
    def free_slots = @slots.size
    def handling = @lock.synchronize { @handling.size }

    private

    def accept_loop
      delay = 0.0
      loop do
        break if @draining
        begin
          sock = @listener.accept
        rescue IOError, SystemCallError => e
          break if @draining || @listener.closed?
          delay = delay == 0.0 ? ACCEPT_BACKOFF_MIN : delay * 2
          delay = ACCEPT_BACKOFF_MAX if delay > ACCEPT_BACKOFF_MAX
          log_accept_error(e, delay)
          Kernel.sleep delay
          next
        end
        delay = 0.0
        if @draining
          close_quietly(sock)
          break
        end
        admit(sock)
      end
    end

    def admit(sock)
      unless @slots.pop(timeout: 0)
        reject(sock)
        return
      end
      handed = false
      begin
        @lock.synchronize do
          box = Outbox.new
          slot = Slot.new(nil, sock, 0.0, :idle, false, false, -1, box)
          th = Thread.new(slot, box) do |s, b|
            Thread.current.report_on_exception = false
            connection(s, b)
          end
          slot.thread = th
          @conns[th] = slot
          handed = true
        end
      rescue Exception => e
        unless handed
          close_quietly(sock)
          @slots << true
        end
        raise if Kiln.unwind?(e)
      end
    end

    def reject(sock)
      begin
        write_fixed(sock, 503, "busy", Kiln.now + 0.5)
        sock.shutdown(Socket::SHUT_WR)
        drained = 0
        while drained < LINGER_BYTES
          chunk = sock.read_nonblock(16_384, exception: false)
          break if chunk.nil? || chunk == :wait_readable
          drained += chunk.bytesize
        end
      rescue IOError, SystemCallError
        nil
      ensure
        close_quietly(sock)
      end
    end

    def reap_loop
      loop do
        waiting = settle_finished
        doomed = nil
        rest = -1.0
        stop = false
        @lock.synchronize do
          if @shut
            stop = @conns.empty?
            @reap_target = NEVER
            rest = 0.01 unless stop
          elsif @handling.empty?
            @reap_target = NEVER
          else
            head = @handling[0]
            due = head.deadline + @kill_grace
            now = Kiln.now
            if head.state != :handling
              heap_remove(head)
              rest = 0.0
            elsif now >= due
              heap_remove(head)
              head.state = :reaping
              @killed += 1
              unless head.done
                notify_timeout(head.sock, head.outbox)
                release_socket(head)
              end
              doomed = head
            else
              @reap_target = due
              rest = due - now
            end
          end
        end
        break if stop
        if doomed
          doomed.thread.kill if doomed.thread&.alive?
        elsif waiting
          @reap_wake.pop(timeout: rest >= 0 && rest < 0.01 ? rest : 0.01)
        elsif rest >= 0
          @reap_wake.pop(timeout: rest)
        else
          @reap_wake.pop
        end
      end
      true
    end

    def notify_timeout(sock, box)
      if box.empty?
        sock.write_nonblock(TIMEOUT_RESPONSE, exception: false)
      else
        sock.write_nonblock(box.data + TIMEOUT_RESPONSE, exception: false)
      end
      true
    rescue IOError, SystemCallError
      false
    end

    def stop_reading(slot)
      slot.sock.shutdown(Socket::SHUT_RD)
      true
    rescue IOError, SystemCallError
      false
    end

    def release_socket(slot)
      slot.sock.shutdown(Socket::SHUT_RDWR)
      true
    rescue IOError, SystemCallError
      false
    end

    def connection(slot, box)
      sock = slot.sock
      safe_io do
        buf = ReadBuffer.new
        buf.outbox = box
        scan = HttpNative.scratch
        budget = @coop_budget
        loop do
          msg = read_request(sock, buf, scan)
          break unless msg
          if msg[0] == :error
            break unless flush_outbox(sock, box, Kiln.now + 1.0)
            write_fixed(sock, msg[1], msg[2], Kiln.now + 1.0, msg[3])
            linger(sock)
            break
          end
          id = begin_handling(slot, msg[2])
          unless id
            break unless flush_outbox(sock, box, Kiln.now + 0.2)
            write_fixed(slot.sock, 503, "shutting down", Kiln.now + 0.2, msg[1].http_version) unless slot.done
            break
          end
          box.mark(!buf.empty? && !buf.index(HEADER_END).nil?)
          break unless serve(msg[1], slot, msg[2], id, box)
          if budget > 0
            budget -= 1
            if budget == 0
              Thread.pass
              budget = @coop_budget
            end
          end
        end
        flush_outbox(sock, box, Kiln.now + 1.0)
      end
    ensure
      if slot.state == :reaping
        finish(slot)
      else
        finalize(slot)
      end
    end

    def finish(slot)
      @finished << slot
      if @reap_wake.empty?
        begin
          @reap_wake.push(true, true)
        rescue ThreadError
          nil
        end
      end
      true
    end

    def settle_finished
      pending = []
      until @finished.empty?
        slot = @finished.pop
        if slot.thread && slot.thread.alive?
          pending << slot
        else
          finalize(slot)
        end
      end
      pending.each { |slot| @finished << slot }
      !pending.empty?
    end

    def finalize(slot)
      first = false
      @lock.synchronize do
        if slot.flying
          slot.flying = false
          @in_flight -= 1
        end
        unhandle(slot)
        unless slot.done
          slot.done = true
          @conns.delete(slot.thread)
          close_quietly(slot.sock)
          first = true
        end
      end
      @slots << true if first
    end

    def signal_reaper
      return unless @reap_wake && @reap_wake.empty?
      @reap_wake.push(true, true)
    rescue ThreadError
      nil
    end
  end
end

require "kiln/server/heap"
require "kiln/server/response"
require "kiln/server/request"
require "kiln/server/io"
