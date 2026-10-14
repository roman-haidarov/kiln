module Kiln
  class Server
    class Base
      include Check

      MAX_HEADER = 16 * 1024
      WRITE_WINDOW = 256 * 1024
      NEVER = 1.0e18
      TIMEOUT_RESPONSE = "HTTP/1.1 504 Gateway Timeout\r\n" \
                         "Content-Type: text/plain\r\n" \
                         "Content-Length: 18\r\n" \
                         "Connection: close\r\n\r\n" \
                         "deadline exceeded\n".b.freeze
      EMPTY_BODY = ''.b.freeze
      LINGER = 0.5
      LINGER_BYTES = 256 * 1024
      ACCEPT_BACKOFF_MIN = 0.005
      ACCEPT_BACKOFF_MAX = 1.0
      CRLF = HttpSyntax::CRLF
      HEADER_END = "\r\n\r\n".b.freeze
      CONTINUE = "HTTP/1.1 100 Continue\r\n\r\n".b.freeze

      Slot = Struct.new(:thread, :sock, :deadline, :state, :done, :flying, :hidx, :outbox, :shard)

      class Outbox
        MAX_COUNT = 16
        MAX_BYTES = 64 * 1024

        attr_reader :data

        def initialize
          @data = (+'').b
          @count = 0
          @more = false
        end

        def mark(more)
          @more = more
        end

        def more? = @more
        def empty? = @data.empty?
        def fits?(size) = @more && @count < MAX_COUNT && @data.bytesize + size <= MAX_BYTES

        def push(head, body = EMPTY_BODY)
          @data << head
          @data << (body.ascii_only? ? body : body.b) unless body.empty?
          @count += 1
        end

        def reset
          @data.clear
          @count = 0
        end
      end

      def initialize(config, app = nil, **options)
        config = BaseOptions.new(handler: config, app: app, **options) unless config.is_a?(BaseOptions)
        @handler = config.handler
        @app = config.app
        @log = config.log
        @port = config.port
        @host = config.host
        @read_timeout = config.read_timeout
        @request_timeout = config.request_timeout
        @write_timeout = config.write_timeout
        @kill_grace = config.kill_grace
        @max_body = config.max_body
        @coop_budget = config.coop_budget
        limit = config.max_conns
        @slots = SizedQueue.new(limit)
        limit.times { @slots << true }
        @lock = Mutex.new
        @conns = {}
        @shard_count = config.shards
        @shard_locks = Array.new(@shard_count) { Mutex.new }
        @handling = Array.new(@shard_count) { [] }
        @in_flight = Array.new(@shard_count, 0)
        @seq = Array.new(@shard_count) { |shard| shard + 1 }
        @killed = Array.new(@shard_count, 0)
        @late = Array.new(@shard_count, 0)
        @shut_by_shard = Array.new(@shard_count, false)
        @next_shard = 0
        @draining = false
        @shut = false
        @listener = nil
        @acceptor = nil
        @reaper = nil
      end

      def start
        raise Errno::EADDRINUSE if @acceptor&.alive? || @reaper&.alive? || connections.positive?

        @draining = false
        @shut = false
        @shut_by_shard.fill(false)
        @handling.each(&:clear)
        @in_flight.fill(0)
        @killed.fill(0)
        @late.fill(0)
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
        check_rules([['shutdown grace', grace, :seconds_at_least]])
        return in_flight if @shut
        return 0 unless @acceptor || @listener

        @lock.synchronize { @draining = true }
        shard = 0
        while shard < @shard_count
          @shard_locks[shard].synchronize { @shut_by_shard[shard] = true }
          shard += 1
        end
        close_quietly(@listener)
        stop_thread(@acceptor)
        deadline = Kiln.now + grace
        Kernel.sleep 0.01 while in_flight.positive? && Kiln.now < deadline
        left = in_flight
        @lock.synchronize do
          @shut = true
          shard = 0
          while shard < @shard_count
            @shard_locks[shard].synchronize { @shut_by_shard[shard] = true }
            shard += 1
          end
        end
        signal_reaper
        slots = @lock.synchronize { @conns.values }
        slots.each { |slot| abandon(slot) }
        slots.each { |slot| quiet_join(slot.thread) if slot.thread }
        quiet_join(@reaper)
        left
      end

      def abandon(slot)
        kill = @shard_locks[slot.shard].synchronize do
          active = !slot.done
          state = slot.state
          handling = active && state == :handling
          writing = active && state == :writing
          if handling
            outbox = slot.outbox
            unless outbox.empty?
              begin
                slot.sock.write_nonblock(outbox.data, exception: false)
              rescue IOError, SystemCallError
                nil
              end
            end
            slot.state = :reaping
          elsif active && !writing
            stop_reading(slot)
          end
          release_socket(slot) if handling || writing
          handling || writing
        end
        thread = slot.thread
        thread.kill if kill && thread&.alive?
      end

      def stop_thread(thread)
        return unless thread

        quiet_join(thread)
        return unless thread.alive?

        thread.kill
        quiet_join(thread)
      rescue Exception
        nil
      end

      def in_flight
        sum_shards(@in_flight)
      end

      def connections = @lock.synchronize { @conns.size }
      def killed = sum_shards(@killed)
      def late = sum_shards(@late)
      def free_slots = @slots.size

      def handling
        total = 0
        shard = 0
        while shard < @shard_count
          total += @shard_locks[shard].synchronize { @handling[shard].size }
          shard += 1
        end
        total
      end

      private

      def accept_loop
        delay = 0.0
        loop do
          break if @draining

          begin
            sock = @listener.accept
          rescue IOError, SystemCallError => err
            break if @draining || @listener.closed?

            delay = delay == 0.0 ? ACCEPT_BACKOFF_MIN : delay * 2
            delay = ACCEPT_BACKOFF_MAX if delay > ACCEPT_BACKOFF_MAX
            log_accept_error(err, delay)
            Kernel.sleep delay
            next
          end
          delay = 0.0
          if HttpNative.kiln_socket_nonblock(sock.fileno).negative?
            close_quietly(sock)
            next
          end
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
            unless @draining || @shut
              shard = @next_shard
              @next_shard = (@next_shard + 1) % @shard_count
              box = Outbox.new
              slot = Slot.new(nil, sock, 0.0, :idle, false, false, -1, box, shard)
              th = Thread.new(slot, box) do |conn, outbox|
                Thread.current.report_on_exception = false
                connection(conn, outbox)
              end
              slot.thread = th
              @conns[th] = slot
              handed = true
            end
          end
          unless handed
            write_fixed(sock, 503, 'shutting down', Kiln.now + 0.2)
            close_quietly(sock)
            @slots << true
            handed = true
          end
        rescue Exception => err
          unless handed
            close_quietly(sock)
            @slots << true
          end
          raise if Kiln.unwind?(err)
        end
      end

      def reject(sock)
        write_fixed(sock, 503, 'busy', Kiln.now + 0.5)
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

      def reap_loop
        loop do
          waiting = settle_finished?
          doomed, rest, stop = reap_once
          break if stop

          if doomed
            thread = doomed.thread
            thread.kill if thread&.alive?
          else
            bounded = rest >= 0
            if waiting
              @reap_wake.pop(timeout: bounded && rest < 0.01 ? rest : 0.01)
            elsif bounded
              @reap_wake.pop(timeout: rest)
            else
              @reap_wake.pop
            end
          end
        end
      end

      def reap_once
        shut, stop = @lock.synchronize { [@shut, @shut && @conns.empty?] }
        return [nil, -1.0, true] if stop
        return [nil, 0.01, false] if shut

        now = Kiln.now
        doomed = nil
        rest = -1.0
        shard = 0
        while shard < @shard_count
          current = shard
          shard += 1
          heap = @handling[current]
          @shard_locks[current].synchronize do
            next if heap.empty?

            head = heap[0]
            due = head.deadline + @kill_grace
            if head.state == :handling && now < due
              remaining = due - now
              rest = remaining if rest < 0 || remaining < rest
            else
              heap_remove(heap, head)
              if head.state == :handling
                head.state = :reaping
                @killed[current] += 1
                doomed = head
              else
                rest = 0.0
              end
            end
          end
          break if doomed
        end
        if doomed
          notify_timeout(doomed.sock, doomed.outbox)
          release_socket(doomed)
        end
        [doomed, rest, false]
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
        safe_io { run_connection(slot, box, slot.sock) }
      ensure
        reaping = @shard_locks[slot.shard].synchronize { slot.state == :reaping }
        reaping ? finish(slot) : finalize(slot)
      end

      def run_connection(slot, box, sock)
        buf = ReadBuffer.new
        buf.outbox = box
        scan = HttpNative.scratch
        budget = @coop_budget
        loop do
          msg = read_request(sock, buf, scan)
          break unless msg
          break unless take_message(slot, box, sock, buf, msg)

          budget = coop_slice(budget)
        end
        flush_outbox(sock, box, Kiln.now + 1.0)
      end

      def take_message(slot, box, sock, buf, msg)
        kind = msg[0]
        payload = msg[1]
        detail = msg[2]
        if kind == :error
          return false unless flush_outbox(sock, box, Kiln.now + 1.0)

          write_fixed(sock, payload, detail, Kiln.now + 1.0, msg[3])
          linger(sock)
          return false
        end
        id = begin_handling(slot, detail)
        unless id
          return false unless flush_outbox(sock, box, Kiln.now + 0.2)

          done = @shard_locks[slot.shard].synchronize { slot.done }
          write_fixed(slot.sock, 503, 'shutting down', Kiln.now + 0.2, payload.http_version) unless done
          return false
        end
        box.mark(!buf.empty? && !buf.index(HEADER_END).nil?)
        serve(payload, slot, detail, id, box)
      end

      def coop_slice(budget)
        return budget unless budget.positive?

        budget -= 1
        return budget unless budget.zero?

        Thread.pass
        @coop_budget
      end

      def finish(slot)
        @finished << slot
        signal_reaper
      end

      def settle_finished?
        pending = []
        until @finished.empty?
          slot = @finished.pop
          if slot.thread&.alive?
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
        @shard_locks[slot.shard].synchronize do
          first = !slot.done
          slot.done = true if first
          slot.state = :idle unless slot.state == :reaping
          if slot.flying
            slot.flying = false
            @in_flight[slot.shard] -= 1
          end
          unhandle(slot)
        end
        if first
          close_quietly(slot.sock)
          @lock.synchronize do
            @slots << true
            @conns.delete(slot.thread)
          end
        end
      end

      def sum_shards(values)
        total = 0
        values.each_index { |shard| total += @shard_locks[shard].synchronize { values[shard] } }
        total
      end

      def signal_reaper
        return unless @reap_wake && @reap_wake.empty?

        @reap_wake.push(true, true)
      rescue ThreadError
        nil
      end
    end
  end
end

require 'kiln/server/base/heap'
require 'kiln/server/base/response'
require 'kiln/server/base/request'
require 'kiln/server/base/io'
