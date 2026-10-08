module Kiln
  module Uv
    ffi_lib 'dl'
    ffi_lib 'pthread'
    ffi_func :kiln_uv_listen, %i[str long long long long], :long
    ffi_func :kiln_uv_error_text, [:long], :binstr
    ffi_func :kiln_uv_running, [], :long
    ffi_func :kiln_uv_port, [], :long
    ffi_func :kiln_uv_fd, [], :long
    ffi_func :kiln_uv_poll, [], :long
    ffi_func :kiln_uv_next, %i[int_array long int_array], :binstr
    ffi_func :kiln_uv_send, %i[long long str long str long long], :long
    ffi_func :kiln_uv_abort, %i[long long], :long
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
      HEAD = 'HEAD'.freeze
      BAD_REQUEST = "HTTP/1.1 400 Bad Request\r\nContent-Length: 12\r\nConnection: close\r\n\r\nbad request\n".b.freeze

      attr_reader :port

      def initialize(config, app = nil, **options)
        unless config.is_a?(EventOptions)
          options[:host] = '127.0.0.1' unless options.key?(:host)
          config = EventOptions.new(handler: config, app: app, **options)
        end
        @handler = config.handler
        @app = config.app
        @log = config.log
        @wake_lock = Mutex.new
        @pump_stopping = false
        @in_handler = false
        @uv_closed = false
        @host = config.host
        @port = config.port
        @max_conns = config.max_conns
        @max_body = config.max_body
        @idle_ms = (config.read_timeout * 1000).to_i
        @request_timeout = config.request_timeout
        @handlers = config.handlers
        @lanes = []
        @workers = []
        @done = Queue.new
        @seq = 0
        @inflight = 0
        @cutoff = false
        @dispatch_ready = false
        @aborted_count = 0
        @aborted_taken = 0
        @draining = false
        @quiet = false
        @stop = false
        @stopped = false
        @pump = nil
      end

      def start
        raise IOError, 'another Kiln::Server::Event is already running in this process' if Uv.kiln_uv_running == 1

        rc = Uv.kiln_uv_listen(@host, @port, @max_conns, @max_body, @idle_ms)
        raise IOError, "kiln event server listen failed: #{Uv.kiln_uv_error_text(rc)} (#{rc})" unless rc.zero?

        @port = Uv.kiln_uv_port
        @poller = IO.for_fd(Uv.kiln_uv_fd)
        @handlers.times do
          lane = Queue.new
          @lanes << lane
          @workers << Thread.new do
            Thread.current.report_on_exception = false
            work(lane)
          end
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
        pause = left.zero? ? 0.5 : 0
        stop_threads(@workers, Kiln.now + pause)
        @stop = true
        wake_pump
        stop_pump(Kiln.now + pause)
        left + @aborted_taken + @aborted_count
      end

      def connections = Uv.kiln_uv_open
      def in_flight = @inflight
      def killed = 0
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
          handled = drain_done
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
          IO.select([@poller], nil, nil, drained ? 0.01 : 0.25) if handled.zero?
        end
        drain_done
        Uv.kiln_uv_flush
        Uv.kiln_uv_poll
      ensure
        begin
          @wake_lock.synchronize { @pump_stopping = true }
          @lanes.each(&:close)
          @workers.each(&:kill)
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
        @workers.all? { |thread| !thread.alive? }
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

      def work(lane)
        while (job = lane.pop)
          run(job[0])
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
        return Uv.kiln_uv_send(slot, gen, EMPTY_BODY, 0, EMPTY_BODY, 0, 1) if ctx.gone

        req = ctx.req
        version = req.http_version
        keep = HttpSyntax.persistent?(version, req.headers['connection']) &&
               Uv.kiln_uv_closes_after(slot, gen, @draining ? 1 : 0).zero?
        res = ctx.res
        raw_status = res.status
        status = Response.valid_status?(raw_status) ? raw_status : 500
        payload = Response.payload(raw_status, res.body)
        head = Response.build_head(raw_status, res.headers, payload.bytesize, keep, version: version)
        payload = EMPTY_BODY if req.verb == HEAD || Response.no_body?(status)
        Uv.kiln_uv_send(slot, gen, head, head.bytesize, payload, payload.bytesize, keep ? 0 : 1)
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

    private_constant :Event
  end
end
