module Kiln
  module Uv
    ffi_lib 'dl'
    ffi_lib 'pthread'
    ffi_func :kiln_uv_configure, %i[int_array long], :long
    ffi_func :kiln_uv_adopt, %i[long long], :long
    ffi_func :kiln_uv_start, [], :long
    ffi_func :kiln_uv_abandon, [], :long
    ffi_func :kiln_uv_error_text, [:long], :binstr
    ffi_func :kiln_uv_running, [], :long
    ffi_func :kiln_uv_port, [:long], :long
    ffi_func :kiln_uv_fd, [], :long
    ffi_func :kiln_uv_poll, [], :long
    ffi_func :kiln_uv_settle, [], :long
    ffi_func :kiln_uv_timeout, [], :long
    ffi_func :kiln_uv_next, %i[int_array long int_array], :binstr
    ffi_func :kiln_uv_send, %i[long long str long str long long], :long
    ffi_func :kiln_uv_abort, %i[long long], :long
    ffi_func :kiln_uv_end, %i[long long], :long
    ffi_func :kiln_uv_part, %i[long long str long], :long
    ffi_func :kiln_uv_backlog, %i[long long], :long
    ffi_func :kiln_uv_flush, [], :long
    ffi_func :kiln_uv_open, [], :long
    ffi_func :kiln_uv_stop, [], :long
    ffi_func :kiln_uv_wake, [], :long
    ffi_func :kiln_uv_drain, [], :long
    ffi_func :kiln_uv_busy, [], :long
    ffi_func :kiln_uv_aborted, [], :long
    ffi_func :kiln_uv_handshakes, [], :long
    ffi_func :kiln_uv_closes_after, %i[long long long], :long
    ffi_func :kiln_uv_body_take, %i[long long long int_array], :binstr
    ffi_func :kiln_uv_body_finish, %i[long long long], :long
    ffi_func :kiln_uv_tunnel, %i[long long str long], :long
    ffi_func :kiln_uv_tls_alpn, %i[long long], :binstr
    ffi_func :kiln_uv_sigpipe_enter, [], :long
    ffi_func :kiln_uv_sigpipe_leave, [], :long
  end

  class Server
    class Event
      include Check

      EMPTY_BODY = ''.b.freeze
      LIVENESS_EVERY = 1.0
      HEAD = 'HEAD'.freeze
      META = 8
      STREAMED = 1
      TLS_FLAG = 8
      TAKE_DATA = 1
      TAKE_EOF = 2
      TAKE_WAIT = 0
      BAD_REQUEST = "HTTP/1.1 400 Bad Request\r\nContent-Length: 12\r\nConnection: close\r\n\r\nbad request\n".b.freeze

      Job = Struct.new(:ctx, :slot, :gen, :thread, :claimed, :claim_lock) do
        def claim!
          claim_lock.synchronize do
            return false if claimed

            self.claimed = true
          end
        end
      end

      attr_reader :port, :killed, :ports

      def initialize(config, app = nil, **options)
        unless config.is_a?(EventOptions)
          options[:host] = '127.0.0.1' unless options.key?(:host)
          config = EventOptions.new(handler: config, app: app, **options)
        end
        @handler = config.handler
        @app = config.app
        @log = config.log
        @wake_lock = Mutex.new
        @parked = false
        @wake_at = 0.0
        @inline_busy = false
        @pump_stopping = false
        @uv_closed = false
        @listen = Listen.resolve(config.listen, config.host, config.port, config.tls)
        @port = config.port
        @ports = []
        @owned_paths = []
        @reuse_port = config.reuse_port
        @max_conns = config.max_conns
        @max_streams = config.max_streams
        @max_body = config.max_body
        @buffer_body = config.buffer_body.nil? ? config.max_body : config.buffer_body
        @read_timeout = config.read_timeout
        @settings = [config.max_conns, @buffer_body, millis(config.header_timeout || config.read_timeout),
                     millis(config.keep_alive_timeout || config.read_timeout), millis(config.read_timeout),
                     millis(config.write_timeout), millis(config.client_disconnect_timeout),
                     config.tcp_nodelay ? 1 : 0, config.max_connection_rate, config.backlog]
        @keep_alive = (config.keep_alive_timeout || config.read_timeout).positive?
        @write_timeout = config.write_timeout
        @outlets = {}
        @inlets = {}
        @thirsty = {}
        @wants = Queue.new
        @take_state = [0]
        @backlogged = {}
        @ready = Queue.new
        @liveness_at = 0.0
        @request_timeout = config.request_timeout
        @handlers = config.handlers
        @lanes = []
        @workers = []
        @worker_lock = Mutex.new
        @retired = [Thread.current].drop(1)
        @active = Array.new(@handlers)
        @active_locks = Array.new(@handlers) { Mutex.new }
        @uploads = {}
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

        Sock.kiln_sock_ignore_sigpipe
        open_listeners
        @poller = IO.for_fd(Uv.kiln_uv_fd, autoclose: false)
        @handlers.times do |index|
          @lanes << Queue.new
          @workers << start_worker(index)
        end
        @pump = Thread.new do
          Thread.current.report_on_exception = false
          rc = Uv.kiln_uv_sigpipe_enter
          raise IOError, "cannot block SIGPIPE on event thread (#{rc})" unless rc.zero?

          begin
            pump
          ensure
            Uv.kiln_uv_sigpipe_leave
          end
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
        release_listeners
        left + @aborted_taken + @aborted_count
      end

      def stream_ready(outlet)
        @ready << outlet
        nudge_pump
      end

      def inlet_wanted(inlet)
        @wants << inlet
        nudge_pump
      end

      def draining? = @draining

      def connections = Uv.kiln_uv_open
      def in_flight = @inflight
      def late = 0
      def free_slots = @max_conns - connections
      def handling = @inflight
      def handshakes = Uv.kiln_uv_handshakes

      private

      def millis(seconds) = (seconds * 1000).to_i

      def open_listeners
        rc = Uv.kiln_uv_configure(@settings, @settings.size)
        raise IOError, "kiln event server setup failed: #{Uv.kiln_uv_error_text(rc)} (#{rc})" unless rc.zero?

        begin
          @listen.each { |spec| adopt(spec) }
          rc = Uv.kiln_uv_start
          raise IOError, "kiln event server listen failed: #{Uv.kiln_uv_error_text(rc)} (#{rc})" unless rc.zero?
        rescue Exception
          Uv.kiln_uv_abandon
          release_listeners
          raise
        end
        @ports = Array.new(@listen.size) { |index| Uv.kiln_uv_port(index) }
        @port = Kiln.first_port(@ports)
      end

      def adopt(spec)
        fd = spec.open(@settings[9], @reuse_port)
        @owned_paths << Sock.own_path(spec.path) if spec.owns_path?
        tls = spec.tls
        context = tls.nil? ? -1 : tls.context
        index = Uv.kiln_uv_adopt(fd, context)
        if index.negative?
          Sock.kiln_sock_close(fd) if spec.kind != :fd
          raise IOError, "kiln event server cannot use #{spec}: #{Uv.kiln_uv_error_text(index)} (#{index})"
        end
      end

      def release_listeners
        @owned_paths.each { |record| Sock.unlink_owned(record) }
        @owned_paths.clear
        @listen.each { |spec| spec.tls&.release }
      end

      def pump
        scan = Array.new(HttpNative::CAP, 0)
        meta = Array.new(META, 0)
        drained = false
        until @stop && workers_stopped?
          begin
            if @draining && !drained
              Uv.kiln_uv_drain
              @inlets.each_value(&:nudge)
              drained = true
            end
            Uv.kiln_uv_poll
            handled = drain_done + pump_streams + expire_handlers
            handled += pump_inlets unless @inlets.empty?
            handled += expire_uploads unless @uploads.empty?
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
            park(drained ? 0.01 : handler_wait) if handled.zero? && Uv.kiln_uv_settle.zero?
          rescue DeadlineExceeded
            nil
          end
        end
        drain_done
        Uv.kiln_uv_flush
        Uv.kiln_uv_poll
      ensure
        begin
          @outlets.each_value(&:halt)
          @inlets.each_value(&:halt)
          @uploads.each_value { |job| job.thread&.kill }
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

      def living(threads)
        kept = [Thread.current].drop(1)
        threads.each { |thread| kept << thread if thread.alive? }
        kept
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
        return wait if @uploads.empty?

        @uploads.each_value do |upload|
          left = upload.ctx.deadline - now
          return 0 if left <= 0

          wait = left if left < wait
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
              @retired = living(@retired)
              @retired << worker
              @workers[index] = start_worker(index) unless @stop
            end
            ctx, slot, gen = job
            @done << [timed_out(ctx), slot, gen]
            @killed += 1
            expired += 1
          end
          index += 1
        end
        expired
      end

      def expire_uploads
        now = Kiln.now
        expired = 0
        @uploads.values.each do |job|
          next unless job.ctx.deadline <= now && job.claim!

          job.thread&.kill
          @uploads.delete(job.slot)
          @done << [timed_out(job.ctx), job.slot, job.gen]
          @killed += 1
          expired += 1
        end
        expired
      end

      def timed_out(ctx)
        timed = Context.new(ctx.req, Response.new, ctx.app, ctx.id, ctx.deadline)
        timed.res.text("deadline exceeded\n", status: 504)
        timed
      end

      def wake_pump
        @wake_lock.synchronize { Uv.kiln_uv_wake if wakeable? }
      end

      def nudge_pump(deadline = nil)
        @wake_lock.synchronize do
          return unless @parked
          return if deadline && deadline >= @wake_at

          Uv.kiln_uv_wake if wakeable?
        end
      end

      def wakeable? = !@uv_closed && !@pump_stopping && @pump&.alive? == true

      def park(timeout)
        uv_timeout = Uv.kiln_uv_timeout
        libuv_wait = uv_timeout * 0.001
        timeout = libuv_wait if uv_timeout >= 0 && libuv_wait < timeout
        @wake_lock.synchronize do
          @parked = true
          @wake_at = Kiln.now + timeout
        end
        IO.select([@poller], nil, nil, timeout) if @done.empty? && @ready.empty? && (@inlets.empty? || @wants.empty?)
      ensure
        @wake_lock.synchronize { @parked = false }
      end

      def fallback_context(ctx, status, body)
        response = Response.new
        response.text(body, status:)
        fallback = Context.new(ctx.req, response, ctx.app, ctx.id, ctx.deadline)
        fallback.gone = ctx.gone
        fallback
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
            thread.kill if @inline_busy && !@pump_stopping
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
        return reply_bad(meta) if parsed.nil?

        version, verb, target, headers = parsed
        target, status = check_event_head(version, verb, target, headers)
        return reply_bad(meta) if status == 400
        return reply_error(meta, status, version) if status.positive?

        flags = meta[5]
        streamed = flags.anybits?(STREAMED)
        req = build_request(src, meta, flags, version, verb, target, headers)
        @seq += 1
        ctx = Context.new(req, Response.new, @app, @seq, Kiln.now + @request_timeout)
        @inflight += 1
        if @handlers.positive?
          @lanes[slot % @handlers] << [ctx, slot, gen]
          return 0
        end
        return spawn_upload(ctx, slot, gen) if streamed

        begin
          @wake_lock.synchronize { @inline_busy = true }
          begin
            run(ctx)
          ensure
            @wake_lock.synchronize { @inline_busy = false }
          end
          if Kiln.now >= ctx.deadline
            deliver(fallback_context(ctx, 504, "deadline exceeded\n"), slot, gen)
          else
            deliver(ctx, slot, gen)
          end
        ensure
          @inflight -= 1
        end
      end

      def check_event_head(version, verb, target, headers)
        return [nil, 501] if verb == 'CONNECT'

        absolute = target.match?(HttpSyntax::ABSOLUTE_FORM)
        if target == '*'
          return [nil, 400] unless verb == 'OPTIONS'
        elsif !target.start_with?('/') && !absolute
          return [nil, 400]
        end
        host = headers['host']
        missing_host = host.nil?
        empty_host = !missing_host && host.empty?
        return [nil, 400] if version == '1.1' && (missing_host || (!absolute && empty_host))
        return [nil, 400] if host && !empty_host && !HttpNative.host?(host)

        if absolute
          target, authority = HttpSyntax.absolute_target(target)
          return [nil, 400] unless target

          headers['host'] = authority
        end
        [target, 0]
      end

      def reply_error(meta, status, version)
        _code, message = HttpSyntax::ERRORS.fetch(:not_implemented)
        body = "#{message}\n".b
        response = Response.new
        response.text(body, status: status)
        head = Response.build_head(status, response.headers, body.bytesize, false, version: version)
        Uv.kiln_uv_send(meta[3], meta[4], head, head.bytesize, body, body.bytesize, 1)
      end

      def build_request(src, meta, flags, version, verb, target, headers)
        slot = meta[3]
        gen = meta[4]
        scheme = Request::HTTP
        alpn = Request::NO_PROTOCOL
        if flags.anybits?(TLS_FLAG)
          scheme = Request::HTTPS
          alpn = Uv.kiln_uv_tls_alpn(slot, gen)
        end
        unless flags.anybits?(STREAMED)
          length = meta[2]
          body = length.positive? ? src.byteslice(meta[1], length) : EMPTY_BODY
          return Request.new(verb, target, headers, body, http_version: version, scheme:, alpn:)
        end

        inlet = Inlet.new(self, slot, gen, @read_timeout)
        @inlets[slot] = inlet
        declared = meta[6]
        payload = Payload.new(inlet, declared.negative? ? nil : declared, @max_body)
        Request.new(verb, target, headers, EMPTY_BODY, http_version: version, payload: payload, scheme:, alpn:)
      end

      def spawn_upload(ctx, slot, gen)
        job = Job.new(ctx, slot, gen, nil, false, Mutex.new)
        @uploads[slot] = job
        job.thread = Thread.new do
          Thread.current.report_on_exception = false
          run(ctx) if Kiln.now < ctx.deadline
          if job.claim!
            @done << [Kiln.now >= ctx.deadline ? fallback_context(ctx, 504, "deadline exceeded\n") : ctx, slot, gen]
            nudge_pump
          end
        end
        0
      end

      def work(lane, index)
        while (job = lane.pop)
          @active_locks[index].synchronize { @active[index] = job }
          ctx = job[0]
          nudge_pump(ctx.deadline)
          run(ctx) if Kiln.now < ctx.deadline
          job[0] = fallback_context(ctx, 504, "deadline exceeded\n") if Kiln.now >= ctx.deadline
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
          nudge_pump
        end
      end

      def drain_done
        count = 0
        until @done.empty?
          ctx, slot, gen = @done.pop
          forget_upload(slot, gen) unless @uploads.empty?
          deliver(ctx, slot, gen)
          @inflight -= 1
          count += 1
        end
        count
      end

      def forget_upload(slot, gen)
        upload = @uploads[slot]
        @uploads.delete(slot) if upload && upload.gen == gen
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

      def settle_body(ctx, slot, gen)
        return 0 if @inlets.empty?

        inlet = @inlets[slot]
        if inlet && inlet.gen == gen
          @inlets.delete(slot)
          @thirsty.delete(slot)
          inlet.halt
        end
        req = ctx.req
        return 0 unless req.streamed?

        Uv.kiln_uv_body_finish(slot, gen, req.payload.failed? ? 1 : 0)
      end

      def deliver(ctx, slot, gen)
        outlet = @outlets[slot]
        return outlet.hold_back(ctx) if outlet && outlet.gen == gen

        unread = settle_body(ctx, slot, gen)
        return Uv.kiln_uv_send(slot, gen, EMPTY_BODY, 0, EMPTY_BODY, 0, 1) if ctx.gone

        req = ctx.req
        res = ctx.res
        return open_tunnel(ctx, slot, gen) if Response.tunnels?(res)

        version = req.http_version
        keep = unread.zero? && HttpSyntax.persistent?(version, req.headers['connection']) &&
               Uv.kiln_uv_closes_after(slot, gen, @draining ? 1 : 0).zero?
        return open_stream(ctx, slot, gen, keep) if Response.streams?(res)

        raw_status = res.status
        status = Response.valid_status?(raw_status) ? raw_status : 500
        payload = Response.payload(raw_status, res.body)
        head = Response.build_head(raw_status, res.headers, payload.bytesize, keep, version: version)
        payload = EMPTY_BODY if req.verb == HEAD || Response.no_body?(status)
        Uv.kiln_uv_send(slot, gen, head, head.bytesize, payload, payload.bytesize, keep ? 0 : 1)
      end

      def open_tunnel(ctx, slot, gen)
        return deliver(fallback_context(ctx, 503, "too many streams\n"), slot, gen) if @outlets.size >= @max_streams
        return deliver(fallback_context(ctx, 503, "shutting down\n"), slot, gen) if @draining

        res = ctx.res
        head = res.upgrade_head
        return Uv.kiln_uv_abort(slot, gen) if Uv.kiln_uv_tunnel(slot, gen, head, head.bytesize).negative?

        outlet = Outlet.new(self, slot, gen, false, false)
        outlet.tunnel = true
        inlet = Inlet.new(self, slot, gen, @read_timeout)
        @inlets[slot] = inlet
        @outlets[slot] = outlet
        @inflight += 1
        body = res.tunnel_body
        id = ctx.id
        outlet.thread = Thread.new { run_tunnel(outlet, inlet, body, id) }
        0
      end

      def run_tunnel(outlet, inlet, body, id)
        Thread.current[:request_id] = id
        failed = true
        body.call(Tunnel.new(inlet, outlet, @write_timeout))
        failed = false
      rescue ClientGone
        nil
      rescue Exception => err
        raise err if Kiln.unwind?(err)

        @log.error("upgrade #{err.class}: #{err.message}")
      ensure
        outlet.complete(failed)
      end

      def open_stream(ctx, slot, gen, keep)
        req = ctx.req
        res = ctx.res
        version = req.http_version
        chunked, keep = Response.stream_framing(res, version, keep)
        head = Response.build_head(res.status, res.headers, Response.stream_size(res.stream_length), keep, version:)
        if req.verb == HEAD
          return Uv.kiln_uv_send(slot, gen, head, head.bytesize, EMPTY_BODY, 0, keep ? 0 : 1)
        end
        return deliver(fallback_context(ctx, 503, "too many streams\n"), slot, gen) if @outlets.size >= @max_streams
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

      def pump_inlets
        until @wants.empty?
          inlet = @wants.pop
          current = @inlets[inlet.slot]
          @thirsty[inlet.slot] = inlet if current.equal?(inlet)
        end
        return 0 if @thirsty.empty?

        count = 0
        @thirsty.values.each do |inlet|
          data = Uv.kiln_uv_body_take(inlet.slot, inlet.gen, inlet.want, @take_state)
          state = @take_state[0]
          next if state == TAKE_WAIT

          @thirsty.delete(inlet.slot)
          if state == TAKE_DATA
            inlet.offer(data)
          elsif state == TAKE_EOF
            inlet.finish
          else
            inlet.fail_with(state)
          end
          count += 1
        end
        count
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
        if outlet.tunnel
          inlet = @inlets[slot]
          if inlet && inlet.gen == gen
            @inlets.delete(slot)
            @thirsty.delete(slot)
            inlet.halt
          end
          return Uv.kiln_uv_end(slot, gen)
        end
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
        Kiln.apply_reply(ctx, reply)
      end
    end

    class Outlet
      HIGH_WATER = 256 * 1024

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
        @pending = [''.b].drop(1)
        @queued = 0
        @backlog = 0
        @gone = false
        @finished = false
        @failed = false
        @flagged = false
        @deferred = nil
        @thread = nil
        @tunnel = false
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
