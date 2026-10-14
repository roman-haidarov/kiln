module Kiln
  module Uv
    ffi_lib 'dl'
    ffi_lib 'pthread'
    ffi_func :kiln_uv_listen, %i[str long long long long long], :long
    ffi_func :kiln_uv_error_text, [:long], :binstr
    ffi_func :kiln_uv_running, [], :long
    ffi_func :kiln_uv_port, [], :long
    ffi_func :kiln_uv_fd, [], :long
    ffi_func :kiln_uv_poll, [], :long
    ffi_func :kiln_uv_next, %i[int_array long int_array], :binstr
    ffi_func :kiln_uv_send, %i[long long str long str long long], :long
    ffi_func :kiln_uv_abort, %i[long long], :long
    ffi_func :kiln_uv_part, %i[long long str long], :long
    ffi_func :kiln_uv_backlog, %i[long long], :long
    ffi_func :kiln_uv_flush, [], :long
    ffi_func :kiln_uv_open, [], :long
    ffi_func :kiln_uv_stop, [], :long
    ffi_func :kiln_uv_wake, [], :long
    ffi_func :kiln_uv_drain, [], :long
    ffi_func :kiln_uv_busy, [], :long
    ffi_func :kiln_uv_aborted, [], :long
    ffi_func :kiln_uv_closes_after, %i[long long long], :long
  end

  class Server
    class Event
      include Check

      EMPTY_BODY = ''.b.freeze
      LIVENESS_EVERY = 1.0
      HEAD = 'HEAD'.freeze
      BAD_REQUEST = "HTTP/1.1 400 Bad Request\r\nContent-Length: 12\r\nConnection: close\r\n\r\nbad request\n".b.freeze

      attr_reader :port, :killed

      def initialize(config, app = nil, **options)
        unless config.is_a?(EventOptions)
          options[:host] = '127.0.0.1' unless options.key?(:host)
          config = EventOptions.new(handler: config, app: app, **options)
        end
        @handler = config.handler
        @app = config.app
        @log = config.log
        @wake_lock = Mutex.new
        @in_handler = false
        @pump_stopping = false
        @uv_closed = false
        @host = config.host
        @port = config.port
        @max_conns = config.max_conns
        @max_body = config.max_body
        @idle_ms = (config.read_timeout * 1000).to_i
        @write_ms = (config.write_timeout * 1000).to_i
        @write_ms = 1 if @write_ms < 1
        @write_timeout = config.write_timeout
        @outlets = {}
        @backlogged = {}
        @ready = Queue.new
        @liveness_at = 0.0
        @request_timeout = config.request_timeout
        @handlers = config.handlers
        @lanes = []
        @workers = []
        @worker_lock = Mutex.new
        @retired = []
        @active = Array.new(@handlers)
        @active_locks = Array.new(@handlers) { Mutex.new }
        @done = Queue.new
        @seq = 0
        @inflight = 0
        @cutoff = false
        @dispatch_ready = false
        @aborted_count = 0
        @aborted_taken = 0
        @killed = 0
        @draining = false
        @quiet = false
        @stop = false
        @stopped = false
        @pump = nil
      end

      def start
        raise IOError, 'another Kiln::Server::Event is already running in this process' if Uv.kiln_uv_running == 1

        rc = Uv.kiln_uv_listen(@host, @port, @max_conns, @max_body, @idle_ms, @write_ms)
        raise IOError, "kiln event server listen failed: #{Uv.kiln_uv_error_text(rc)} (#{rc})" unless rc.zero?

        @port = Uv.kiln_uv_port
        @poller = IO.for_fd(Uv.kiln_uv_fd, autoclose: false)
        @handlers.times do |index|
          @lanes << Queue.new
          @workers << start_worker(index)
        end
        @pump = Thread.new do
          Thread.current.report_on_exception = false
          pump
        end
        self
      end

      def shutdown(grace: 5.0)
        check_rules([['shutdown grace', grace, :seconds_at_least]])
        return 0 if @stopped || @pump.nil?

        @stopped = true
        @quiet = false
        @draining = true
        wake_pump
        limit = Kiln.now + grace
        Kernel.sleep 0.01 until @quiet || !@pump.alive? || Kiln.now >= limit
        left = @quiet ? 0 : @inflight
        unless @quiet
          @cutoff = true
          if @handlers.positive?
            wake_pump
            ready_limit = Kiln.now + 0.5
            Kernel.sleep 0.001 until @dispatch_ready || !@pump.alive? || Kiln.now >= ready_limit
            left = @inflight
          end
        end
        @lanes.each(&:close)
        @stop = true
        wake_pump
        pause = left.zero? ? 0.5 : 0
        threads = @worker_lock.synchronize { @workers + @retired }
        stop_threads(threads, Kiln.now + pause)
        wake_pump
        stop_pump(Kiln.now + pause)
        left + @aborted_taken + @aborted_count
      end

      def stream_ready(outlet)
        @ready << outlet
        wake_pump
      end

      def draining? = @draining

      def connections = Uv.kiln_uv_open
      def in_flight = @inflight
      def late = 0
      def free_slots = @max_conns - connections
      def handling = @inflight

      private

      def pump
        scan = Array.new(HttpNative::CAP, 0)
        meta = Array.new(5, 0)
        drained = false
        until @stop && workers_stopped?
          if @draining && !drained
            Uv.kiln_uv_drain
            drained = true
          end
          Uv.kiln_uv_poll
          handled = drain_done + pump_streams + expire_handlers
          loop do
            src = Uv.kiln_uv_next(scan, HttpNative::CAP, meta)
            break if src.empty?

            if @cutoff
              Uv.kiln_uv_abort(meta[3], meta[4])
              @aborted_taken += 1
            else
              serve(src, scan, meta)
            end
            handled += 1
          end
          @dispatch_ready = true if @cutoff
          Uv.kiln_uv_flush
          @quiet = drained && @inflight.zero? && Uv.kiln_uv_busy.zero?
          IO.select([@poller], nil, nil, drained ? 0.01 : handler_wait) if handled.zero?
        end
        drain_done
        Uv.kiln_uv_flush
        Uv.kiln_uv_poll
      ensure
        begin
          @outlets.each_value(&:halt)
          @wake_lock.synchronize { @pump_stopping = true }
          @lanes.each(&:close)
          @workers.each(&:kill)
          @retired.each(&:kill)
          Kernel.sleep 0.01 until workers_stopped?
        ensure
          @wake_lock.synchronize do
            unless @uv_closed
              Uv.kiln_uv_stop
              @aborted_count = Uv.kiln_uv_aborted
              @uv_closed = true
            end
          end
        end
      end

      def workers_stopped?
        @workers.all? { |thread| !thread.alive? } && @retired.all? { |thread| !thread.alive? }
      end

      def start_worker(index)
        Thread.new do
          Thread.current.report_on_exception = false
          work(@lanes[index], index)
        end
      end

      def handler_wait
        now = Kiln.now
        wait = 0.25
        index = 0
        while index < @handlers
          job = @active_locks[index].synchronize { @active[index] }
          if job
            left = job[0].deadline - now
            return 0 if left <= 0

            wait = left if left < wait
          end
          index += 1
        end
        wait
      end

      def expire_handlers
        now = Kiln.now
        expired = 0
        index = 0
        while index < @handlers
          job = @active_locks[index].synchronize do
            current = @active[index]
            if current && current[0].deadline <= now
              @active[index] = nil
              current
            end
          end
          if job
            @worker_lock.synchronize do
              worker = @workers[index]
              worker.kill if worker.alive?
              @retired << worker
              @retired.select!(&:alive?)
              @workers[index] = start_worker(index) unless @stop
            end
            ctx, slot, gen = job
            timed = Context.new(ctx.req, Response.new, ctx.app, ctx.id, ctx.deadline)
            timed.res.text("deadline exceeded\n", status: 504)
            @done << [timed, slot, gen]
            @killed += 1
            expired += 1
          end
          index += 1
        end
        expired
      end

      def wake_pump
        @wake_lock.synchronize do
          Uv.kiln_uv_wake if !@uv_closed && !@pump_stopping && @pump && @pump.alive?
        end
      end

      def stop_threads(threads, deadline)
        threads.each do |thread|
          wait_dead(thread, deadline)
          thread.kill if thread.alive?
          wait_dead(thread, Kiln.now + 1.0)
          next if thread.alive?

          self.join_or_log(thread)
        end
      end

      def stop_pump(deadline)
        thread = @pump
        wait_dead(thread, deadline)
        if thread.alive?
          @wake_lock.synchronize do
            thread.kill if @in_handler && !@pump_stopping
          end
        end
        wait_dead(thread, Kiln.now + 1.0)
        return if thread.alive?

        self.join_or_log(thread)
      end

      def wait_dead(thread, deadline)
        Kernel.sleep 0.01 while thread.alive? && Kiln.now < deadline
      end

      def join_or_log(thread)
        thread.join
      rescue StandardError => err
        @log.error("event server thread stopped with #{err.class}: #{err.message}")
      end

      def serve(src, scan, meta)
        parsed = HttpNative.build(src, meta[0], scan)
        slot = meta[3]
        gen = meta[4]
        bad = parsed.nil?
        unless bad
          version, verb, target, headers = parsed
          host = headers['host']
          missing_host = host.nil?
          empty_host = !missing_host && host.empty?
          bad = (version == '1.1' && (missing_host || empty_host)) ||
                (host && !empty_host && !HttpNative.host?(host)) ||
                !target.start_with?('/')
        end
        return reply_bad(meta) if bad

        length = meta[2]
        body = length.positive? ? src.byteslice(meta[1], length) : EMPTY_BODY
        req = Request.new(verb, target, headers, body, http_version: version)
        @seq += 1
        ctx = Context.new(req, Response.new, @app, @seq, Kiln.now + @request_timeout)
        if @handlers.positive?
          @inflight += 1
          @lanes[slot % @handlers] << [ctx, slot, gen]
          return 0
        end
        @inflight += 1
        @wake_lock.synchronize { @in_handler = true }
        begin
          run(ctx)
        ensure
          @wake_lock.synchronize { @in_handler = false }
        end
        deliver(ctx, slot, gen)
        @inflight -= 1
      end

      def work(lane, index)
        while (job = lane.pop)
          @active_locks[index].synchronize { @active[index] = job }
          wake_pump
          ctx = job[0]
          run(ctx) if Kiln.now < ctx.deadline
          ctx.res.text("deadline exceeded\n", status: 504) if Kiln.now >= ctx.deadline
          accepted = @active_locks[index].synchronize do
            if @active[index].equal?(job)
              @active[index] = nil
              true
            else
              false
            end
          end
          break unless accepted

          @done << job
          wake_pump
        end
      end

      def drain_done
        count = 0
        until @done.empty?
          ctx, slot, gen = @done.pop
          deliver(ctx, slot, gen)
          @inflight -= 1
          count += 1
        end
        count
      end

      def run(ctx)
        current = Thread.current
        current[:kiln_deadline] = ctx.deadline
        current[:request_id] = ctx.id
        begin
          dispatch(ctx)
        ensure
          current[:kiln_deadline] = nil
          current[:request_id] = nil
        end
      end

      def deliver(ctx, slot, gen)
        outlet = @outlets[slot]
        return outlet.hold_back(ctx) if outlet && outlet.gen == gen
        return Uv.kiln_uv_send(slot, gen, EMPTY_BODY, 0, EMPTY_BODY, 0, 1) if ctx.gone

        req = ctx.req
        version = req.http_version
        keep = HttpSyntax.persistent?(version, req.headers['connection']) &&
               Uv.kiln_uv_closes_after(slot, gen, @draining ? 1 : 0).zero?
        res = ctx.res
        return open_stream(ctx, slot, gen, keep) if Response.streams?(res)

        raw_status = res.status
        status = Response.valid_status?(raw_status) ? raw_status : 500
        payload = Response.payload(raw_status, res.body)
        head = Response.build_head(raw_status, res.headers, payload.bytesize, keep, version: version)
        payload = EMPTY_BODY if req.verb == HEAD || Response.no_body?(status)
        Uv.kiln_uv_send(slot, gen, head, head.bytesize, payload, payload.bytesize, keep ? 0 : 1)
      end

      def open_stream(ctx, slot, gen, keep)
        req = ctx.req
        res = ctx.res
        version = req.http_version
        chunked, keep = Response.stream_framing(res, version, keep)
        size = res.stream_length
        head = Response.build_head(res.status, res.headers, size.nil? ? -1 : size, keep, version:)
        if req.verb == HEAD
          return Uv.kiln_uv_send(slot, gen, head, head.bytesize, EMPTY_BODY, 0, keep ? 0 : 1)
        end
        return -1 if Uv.kiln_uv_part(slot, gen, head, head.bytesize).negative?

        spawn_stream(ctx, Outlet.new(self, slot, gen, keep, chunked))
      end

      def spawn_stream(ctx, outlet)
        @outlets[outlet.slot] = outlet
        @inflight += 1
        res = ctx.res
        body = res.stream_body
        length = res.stream_length
        id = ctx.id
        outlet.thread = Thread.new { run_stream(outlet, body, length, id) }
        0
      end

      def run_stream(outlet, body, length, id)
        Thread.current[:request_id] = id
        failed = true
        out = stream_writer(outlet, length)
        body.call(out)
        out.flush
        out.verify!
        outlet.ending = out.ending
        failed = false
      rescue ClientGone
        nil
      rescue Exception => err
        raise err if Kiln.unwind?(err)

        @log.error("stream #{err.class}: #{err.message}")
      ensure
        outlet.complete(failed)
      end

      def stream_writer(outlet, length)
        timeout = @write_timeout
        Stream.new(->(prefix, bytes) { outlet.enqueue(prefix, bytes, Kiln.now + timeout) }, -> { outlet.closed? },
                   outlet.chunked, length)
      end

      def pump_streams
        count = 0
        until @ready.empty?
          outlet = @ready.pop
          count += 1
          pieces, finished, failed = outlet.drain_pending
          feed(outlet, pieces)
          close_stream(outlet, failed) if finished
        end
        refresh_backlog
        count
      end

      def feed(outlet, pieces)
        slot = outlet.slot
        gen = outlet.gen
        pieces.each do |bytes|
          left = Uv.kiln_uv_part(slot, gen, bytes, bytes.bytesize)
          note_backlog(outlet, left)
          break if left.negative?
        end
      end

      def note_backlog(outlet, left)
        outlet.record_backlog(left)
        if left.positive?
          @backlogged[outlet.slot] = outlet
        else
          @backlogged.delete(outlet.slot)
        end
      end

      def refresh_backlog
        now = Kiln.now
        sweep = now >= @liveness_at
        @liveness_at = now + LIVENESS_EVERY if sweep
        targets = sweep ? @outlets : @backlogged
        return if targets.empty?

        targets.values.each { |outlet| note_backlog(outlet, Uv.kiln_uv_backlog(outlet.slot, outlet.gen)) }
      end

      def close_stream(outlet, failed)
        slot = outlet.slot
        gen = outlet.gen
        @outlets.delete(slot)
        @backlogged.delete(slot)
        @inflight -= 1
        broken = failed || outlet.gone?
        send_ending(outlet, broken)
        outlet.deferred&.each { |ctx| deliver(ctx, slot, gen) } unless broken
      end

      def send_ending(outlet, broken)
        slot = outlet.slot
        gen = outlet.gen
        return Uv.kiln_uv_abort(slot, gen) if broken

        ending = outlet.ending
        Uv.kiln_uv_send(slot, gen, EMPTY_BODY, 0, ending, ending.bytesize, outlet.keep ? 0 : 1)
      end

      def reply_bad(meta)
        Uv.kiln_uv_send(meta[3], meta[4], BAD_REQUEST, BAD_REQUEST.bytesize, EMPTY_BODY, 0, 1)
      end

      def dispatch(ctx)
        @handler.call(ctx)
      rescue ClientGone
        ctx.gone = true
      rescue Exception => err
        reply = Kiln.timeout_reply(err)
        unless reply
          raise err if Kiln.unwind?(err)

          @log.error("#{err.class}: #{err.message}")
          reply = ["internal error\n", 500]
        end
        ctx.res.text(reply[0], status: reply[1])
      end
    end

    class Outlet
      HIGH_WATER = 256 * 1024

      attr_reader :slot, :gen, :keep, :chunked, :deferred
      attr_accessor :thread, :ending

      def initialize(server, slot, gen, keep, chunked)
        @server = server
        @slot = slot
        @gen = gen
        @keep = keep
        @chunked = chunked
        @lock = Mutex.new
        @cond = ConditionVariable.new
        @pending = [''.b].drop(1)
        @queued = 0
        @backlog = 0
        @gone = false
        @finished = false
        @failed = false
        @flagged = false
        @deferred = nil
        @thread = nil
        @ending = Stream::TERMINATOR
      end

      def enqueue(prefix, bytes, limit)
        signal = @lock.synchronize do
          raise ClientGone, 'client went away' if @gone

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
          left = limit - Kiln.now
          if left <= 0
            @gone = true
            break
          end
          @cond.wait(@lock, left)
        end
        raise ClientGone, 'client went away' if @gone
      end
    end

    private_constant :Event, :Outlet
  end
end
