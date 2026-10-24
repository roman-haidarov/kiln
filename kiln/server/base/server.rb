module Kiln
  class Server
    class Base
      include Runtime::Check

      MAX_HEADER = 16 * 1024
      WRITE_WINDOW = 256 * 1024
      NEVER = 1.0e18
      TIMEOUT_RESPONSE = "HTTP/1.1 504 Gateway Timeout\r\n" \
                         "Content-Type: text/plain\r\n" \
                         "Content-Length: 18\r\n" \
                         "Connection: close\r\n\r\n" \
                         "deadline exceeded\n".b.freeze
      EMPTY_BODY = ''.b.freeze
      LINGER_BYTES = 256 * 1024
      DRAIN_MAX = 256 * 1024
      ACCEPT_WAIT = 0.25
      ACCEPT_BACKOFF_MIN = 0.005
      ACCEPT_BACKOFF_MAX = 1.0
      CRLF = HTTP::Syntax::CRLF
      HEADER_END = "\r\n\r\n".b.freeze
      CONTINUE = "HTTP/1.1 100 Continue\r\n\r\n".b.freeze
      CHUNK_END = 1
      CHUNK_TOO_BIG = -2
      CHUNK_HUGE = -3

      Slot = Struct.new(:thread, :sock, :deadline, :state, :done, :flying, :hidx, :outbox, :shard)

      class Outbox
        MAX_COUNT = 16
        MAX_BYTES = 64 * 1024

        attr_reader :data
        attr_accessor :buffer

        def initialize
          @data = (+'').b
          @count = 0
          @more = false
          @buffer = HTTP::ReadBuffer.new
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

      module Setup
        private

        def init_endpoints(config, handler, app)
          @handler = handler
          @app = app
          @log = config.log
          @port = config.port
          @listen = config.listen
          @backlog = config.backlog
          @reuse_port = config.reuse_port?
          @nodelay = config.tcp_nodelay? ? 1 : 0
        end

        def init_timeouts(config)
          @read_timeout = config.read_timeout
          @header_timeout = config.header_timeout
          @keep_alive_timeout = config.keep_alive_timeout
          @keep_alive = @keep_alive_timeout.positive?
          @linger = config.client_disconnect_timeout
          @request_timeout = config.request_timeout
          @write_timeout = config.write_timeout
          @kill_grace = config.kill_grace
        end

        def init_limits(config)
          @max_body = config.max_body
          @buffer_body = config.buffer_body
          @coop_budget = config.coop_budget
          limit = config.max_conns
          @slots = SizedQueue.new(limit)
          limit.times { @slots << true }
          @lock = Mutex.new
          @conns = {}
        end

        def init_shards(count)
          @shard_count = count
          @shard_locks = Array.new(count) { Mutex.new }
          @handling = Array.new(count) { [] }
          @in_flight = Array.new(count, 0)
          @seq = Array.new(count) { |shard| shard + 1 }
          @killed = Array.new(count, 0)
          @late = Array.new(count, 0)
          @shut_by_shard = Array.new(count, false)
          @next_shard = 0
        end

        def init_runtime
          @draining = false
          @shut = false
          @listeners = []
          @owned_paths = []
          @ports = []
          @acceptors = []
          @acceptor = nil
          @reaper = nil
        end
      end

      module Lifecycle
        def start
          raise Errno::EADDRINUSE if @acceptor&.alive? || @reaper&.alive? || connections.positive?

          reset_counters
          Transport::Sock.kiln_sock_ignore_sigpipe
          open_listeners
          @finished = Queue.new
          @reap_wake = SizedQueue.new(1)
          @acceptors = @listeners.map { |listener| spawn_acceptor(listener) }
          @acceptor = @acceptors.first
          @reaper = spawn_reaper
          self
        end

        private

        def reset_counters
          @draining = false
          @shut = false
          @shut_by_shard.fill(false)
          @handling.each(&:clear)
          @in_flight.fill(0)
          @killed.fill(0)
          @late.fill(0)
        end

        def spawn_acceptor(listener)
          Thread.new do
            Thread.current.report_on_exception = false
            accept_loop(listener)
          end
        end

        def spawn_reaper
          Thread.new do
            Thread.current.report_on_exception = false
            reap_loop
          end
        end

        def open_listeners
          @listeners = []
          @ports = []
          opened = false
          begin
            @listen.each { |spec| open_listener(spec) }
            opened = true
          ensure
            release_opened unless opened
          end
        end

        def open_listener(spec)
          fd = spec.open(@backlog, @reuse_port)
          @owned_paths << Transport::Sock.own_path(spec.path) if spec.owns_path?
          @listeners << IO.for_fd(fd, autoclose: true)
          @ports << Transport::Sock.kiln_sock_port(fd)
        end

        def release_opened
          @listeners.each { |listener| close_quietly(listener) }
          @listeners = []
          @owned_paths.each { |record| Transport::Sock.unlink_owned(record) }
          @owned_paths = []
        end
      end

      module Shutdown
        def shutdown(grace: 5.0)
          check_rules([['shutdown grace', grace, :seconds_at_least]])
          return in_flight if @shut
          return 0 unless @acceptor || !@listeners.empty?

          begin_drain
          wait_in_flight(Kiln::Runtime.now + grace)
          left = in_flight
          finish_shutdown
          left
        end

        def abandon(slot)
          kill = @shard_locks[slot.shard].synchronize { kill_abandoned?(slot) }
          thread = slot.thread
          thread.kill if kill && thread&.alive?
        end

        def stop_thread(thread)
          return unless thread

          quiet_join(thread)
          return unless thread.alive?

          thread.kill
          quiet_join(thread)
        rescue *Kiln::Runtime::FAILURES
          nil
        end

        private

        def begin_drain
          @lock.synchronize { @draining = true }
          mark_shards_shut
          @acceptors.each { |thread| stop_thread(thread) }
          release_opened
        end

        def mark_shards_shut
          shard = 0
          while shard < @shard_count
            @shard_locks[shard].synchronize { @shut_by_shard[shard] = true }
            shard += 1
          end
        end

        def wait_in_flight(deadline)
          Kernel.sleep 0.01 while in_flight.positive? && Kiln::Runtime.now < deadline
        end

        def finish_shutdown
          @lock.synchronize do
            @shut = true
            mark_shards_shut
          end
          signal_reaper
          slots = @lock.synchronize { @conns.values }
          slots.each { |slot| abandon(slot) }
          join_slots(slots)
          quiet_join(@reaper)
        end

        def join_slots(slots)
          slots.each { |slot| quiet_join(slot.thread) if slot.thread }
        end

        def kill_abandoned?(slot)
          return false if slot.done

          state = slot.state
          unless %i[handling writing].include?(state)
            stop_reading(slot)
            return false
          end
          reap_abandoned(slot) if state == :handling
          release_socket(slot)
          true
        end

        def reap_abandoned(slot)
          flush_abandoned(slot)
          slot.state = :reaping
        end

        def flush_abandoned(slot)
          outbox = slot.outbox
          return if outbox.empty?

          slot.sock.write_nonblock(outbox.data, exception: false)
        rescue IOError, SystemCallError
          nil
        end
      end

      module Accepting
        private

        def accept_loop(listener)
          delay = 0.0
          fd = listener.fileno
          until @draining
            client = Transport::Sock.kiln_sock_accept(fd, @nodelay)
            delay = client.negative? ? accept_failed(listener, client, delay) : accept_client(client)
            break if delay.negative?
          end
        rescue IOError, SystemCallError
          nil
        end

        def accept_failed(listener, client, delay)
          return -1.0 if @draining || listener.closed?

          if Transport::Sock.eagain?(client)
            listener.wait_readable(ACCEPT_WAIT)
            return delay
          end
          delay = delay.zero? ? ACCEPT_BACKOFF_MIN : [delay * 2, ACCEPT_BACKOFF_MAX].min
          log_accept_error(Transport::Sock.failure('accept', client), delay)
          Kernel.sleep delay
          delay
        end

        def accept_client(client)
          sock = IO.for_fd(client, autoclose: true)
          if @draining
            close_quietly(sock)
            return -1.0
          end
          admit(sock)
          0.0
        end

        def admit(sock)
          return reject(sock) unless @slots.pop(timeout: 0)

          handed = false
          begin
            refuse_draining(sock) unless spawn_connection(sock)
            handed = true
          rescue *Kiln::Runtime::FAILURES
            nil
          ensure
            release_admission(sock) unless handed
          end
        end

        def spawn_connection(sock)
          @lock.synchronize do
            if @draining || @shut
              false
            else
              start_connection(sock)
              true
            end
          end
        end

        def start_connection(sock)
          shard = @next_shard
          @next_shard = (shard + 1) % @shard_count
          box = Outbox.new
          slot = Slot.new(nil, sock, 0.0, :idle, false, false, -1, box, shard)
          slot.thread = Thread.new(slot, box) do |conn, outbox|
            Thread.current.report_on_exception = false
            connection(conn, outbox)
          end
          @conns[slot.thread] = slot
        end

        def refuse_draining(sock)
          write_fixed(sock, 503, 'shutting down', Kiln::Runtime.now + 0.2)
          close_quietly(sock)
          @slots << true
        end

        def release_admission(sock)
          close_quietly(sock)
          @slots << true
        end

        def reject(sock)
          write_fixed(sock, 503, 'busy', Kiln::Runtime.now + 0.5)
          Transport::Sock.kiln_sock_shutdown(sock.fileno, 1)
          drain_input(sock, Kiln::Runtime.now)
        rescue IOError, SystemCallError
          nil
        ensure
          close_quietly(sock)
        end
      end

      module Reaping
        private

        def reap_loop
          loop do
            waiting = settle_finished?
            doomed, rest, stop = reap_once
            break if stop

            doomed ? kill_doomed(doomed) : reap_wait(waiting, rest)
          end
        end

        def kill_doomed(slot)
          thread = slot.thread
          thread.kill if thread&.alive?
        end

        def reap_wait(waiting, rest)
          bounded = rest >= 0
          if waiting
            @reap_wake.pop(timeout: bounded && rest < 0.01 ? rest : 0.01)
          elsif bounded
            @reap_wake.pop(timeout: rest)
          else
            @reap_wake.pop
          end
        end

        def reap_once
          shut, stop = @lock.synchronize { [@shut, @shut && @conns.empty?] }
          return [nil, -1.0, true] if stop
          return [nil, 0.01, false] if shut

          doomed, rest = scan_shards(Kiln::Runtime.now)
          doom(doomed) if doomed
          [doomed, rest, false]
        end

        def doom(slot)
          notify_timeout(slot.sock, slot.outbox)
          release_socket(slot)
        end

        def scan_shards(now)
          rest = -1.0
          shard = 0
          while shard < @shard_count
            doomed, rest = reap_shard(shard, now, rest)
            return [doomed, rest] if doomed

            shard += 1
          end
          [nil, rest]
        end

        def reap_shard(shard, now, rest)
          heap = @handling[shard]
          @shard_locks[shard].synchronize do
            heap.empty? ? [nil, rest] : reap_head(heap, shard, now, rest)
          end
        end

        def reap_head(heap, shard, now, rest)
          head = heap[0]
          due = head.deadline + @kill_grace
          return [nil, sooner(rest, due - now)] if head.state == :handling && now < due

          heap_remove(heap, head)
          return [nil, 0.0] unless head.state == :handling

          head.state = :reaping
          @killed[shard] += 1
          [head, rest]
        end

        def sooner(rest, remaining) = rest.negative? || remaining < rest ? remaining : rest

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
          Transport::Sock.kiln_sock_shutdown(slot.sock.fileno, 0).zero?
        rescue IOError, SystemCallError
          false
        end

        def release_socket(slot)
          Transport::Sock.kiln_sock_shutdown(slot.sock.fileno, 2).zero?
        rescue IOError, SystemCallError
          false
        end

        def signal_reaper
          return unless @reap_wake && @reap_wake.empty?

          @reap_wake.push(true, true)
        rescue ThreadError
          nil
        end
      end

      module Connections
        private

        def connection(slot, box)
          safe_io { run_connection(slot, box, slot.sock) }
        ensure
          reaping = @shard_locks[slot.shard].synchronize { slot.state == :reaping }
          reaping ? finish(slot) : finalize(slot)
        end

        def run_connection(slot, box, sock)
          serve_requests(slot, box, sock, connection_buffer(box))
          flush_outbox(sock, box, Kiln::Runtime.now + 1.0)
        end

        def connection_buffer(box)
          buf = HTTP::ReadBuffer.new
          buf.outbox = box
          box.buffer = buf
          buf
        end

        def serve_requests(slot, box, sock, buf)
          scan = HTTP::Native.scratch
          budget = @coop_budget
          first = true
          loop do
            msg = read_request(sock, buf, scan, first)
            break unless msg && take_message(slot, box, sock, buf, msg)

            first = false
            budget = coop_slice(budget)
          end
        end

        def take_message(slot, box, sock, buf, msg)
          return reply_error(sock, box, msg) if msg[0] == :error

          req = msg[1]
          deadline = msg[2]
          id = begin_handling(slot, deadline)
          return refuse_request(slot, box, req) if id.zero?

          box.mark(!buf.empty? && !buf.index(HEADER_END).nil?)
          serve(req, slot, deadline, id, box)
        end

        def reply_error(sock, box, msg)
          return unless flush_outbox(sock, box, Kiln::Runtime.now + 1.0)

          write_fixed(sock, msg[1], msg[2], Kiln::Runtime.now + 1.0, msg[3])
          linger(sock)
          nil
        end

        def refuse_request(slot, box, req)
          sock = slot.sock
          return unless flush_outbox(sock, box, Kiln::Runtime.now + 0.2)

          done = @shard_locks[slot.shard].synchronize { slot.done }
          write_fixed(sock, 503, 'shutting down', Kiln::Runtime.now + 0.2, req.http_version) unless done
          nil
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
          finalize_or_keep(@finished.pop, pending) until @finished.empty?
          pending.each { |slot| @finished << slot }
          !pending.empty?
        end

        def finalize_or_keep(slot, pending)
          return pending << slot if slot.thread&.alive?

          finalize(slot)
        end

        def finalize(slot)
          first = @shard_locks[slot.shard].synchronize { settle_slot(slot) }
          return unless first

          close_quietly(slot.sock)
          @lock.synchronize do
            @slots << true
            @conns.delete(slot.thread)
          end
        end

        def settle_slot(slot)
          first = !slot.done
          slot.done = true
          release_slot(slot)
          first
        end
      end

      include Setup
      include Lifecycle
      include Shutdown
      include Accepting
      include Reaping
      include Connections

      def initialize(handler, app = nil, **options)
        config = Settings.base(options)
        init_endpoints(config, handler, app)
        init_timeouts(config)
        init_limits(config)
        init_shards(config.shards)
        init_runtime
      end

      attr_reader :ports

      def port = @ports.empty? ? @port : Kiln::Runtime.first_port(@ports)
      def in_flight = sum_shards(@in_flight)
      def connections = @lock.synchronize { @conns.size }
      def killed = sum_shards(@killed)
      def late = sum_shards(@late)
      def free_slots = @slots.size
      def handshakes = 0

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

      def sum_shards(values)
        total = 0
        values.each_index { |shard| total += @shard_locks[shard].synchronize { values[shard] } }
        total
      end
    end
  end
end

require 'kiln/server/base/heap'
require 'kiln/server/base/response'
require 'kiln/server/base/request'
require 'kiln/server/base/io'
require 'kiln/server/base/body'
