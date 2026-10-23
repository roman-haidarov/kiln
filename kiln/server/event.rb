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
      include Runtime::Check

      EMPTY_BODY = ''.b.freeze
      LIVENESS_EVERY = 1.0
      HANDLER_WAIT = 0.25
      HEAD = 'HEAD'.freeze
      META = 8
      STREAMED = 1
      TLS_FLAG = 8
      TAKE_DATA = 1
      TAKE_EOF = 2
      TAKE_WAIT = 0
      BAD_REQUEST = "HTTP/1.1 400 Bad Request\r\nContent-Length: 12\r\nConnection: close\r\n\r\nbad request\n".b.freeze
      DEADLINE_BODY = "deadline exceeded\n".freeze

      Job = Struct.new(:ctx, :slot, :gen, :thread, :claimed, :claim_lock) do
        def claim!
          claim_lock.synchronize do
            return false if claimed

            self.claimed = true
          end
        end
      end

      module Setup
        private

        def event_options(handler, app, options)
          options[:host] = '127.0.0.1' unless options.key?(:host)
          EventOptions.new(handler: handler, app: app, **options)
        end

        def init_wiring(config)
          @handler = config.handler
          @app = config.app
          @log = config.log
          @listen = Transport::Listen.resolve(config.listen, config.host, config.port, config.tls)
          @port = config.port
          @ports = []
          @owned_paths = []
          @reuse_port = config.reuse_port
          @request_timeout = config.request_timeout
        end

        def init_limits(config)
          @max_conns = config.max_conns
          @max_streams = config.max_streams
          @max_body = config.max_body
          @buffer_body = config.buffer_body.nil? ? config.max_body : config.buffer_body
          @read_timeout = config.read_timeout
          @write_timeout = config.write_timeout
          @keep_alive = (config.keep_alive_timeout || config.read_timeout).positive?
          @handlers = config.handlers
        end

        def init_settings(config)
          @settings = [config.max_conns, @buffer_body] + timeout_settings(config) +
                      [config.tcp_nodelay ? 1 : 0, config.max_connection_rate, config.backlog]
        end

        def timeout_settings(config)
          read = config.read_timeout
          [millis(config.header_timeout || read), millis(config.keep_alive_timeout || read), millis(read),
           millis(config.write_timeout), millis(config.client_disconnect_timeout)]
        end

        def millis(seconds) = (seconds * 1000).to_i

        def init_streams
          @outlets = {}
          @inlets = {}
          @thirsty = {}
          @wants = Queue.new
          @take_state = [0]
          @backlogged = {}
          @ready = Queue.new
          @liveness_at = 0.0
          @uploads = {}
          @done = Queue.new
        end

        def init_workers(count)
          @lanes = []
          @workers = []
          @worker_lock = Mutex.new
          @retired = [Thread.current].drop(1)
          @active = Array.new(count)
          @active_locks = Array.new(count) { Mutex.new }
        end

        def init_wake
          @wake_lock = Mutex.new
          @parked = false
          @wake_at = 0.0
          @inline_busy = false
          @pump_stopping = false
          @uv_closed = false
        end

        def init_flags
          @cutoff = false
          @dispatch_ready = false
          @draining = false
          @quiet = false
          @stop = false
          @stopped = false
          @pump = nil
        end

        def init_counters
          @seq = 0
          @inflight = 0
          @aborted_count = 0
          @aborted_taken = 0
          @killed = 0
        end
      end

      module Lifecycle
        def start
          raise IOError, 'another Kiln::Server::Event is already running in this process' if Uv.kiln_uv_running == 1

          Transport::Sock.kiln_sock_ignore_sigpipe
          open_listeners
          @poller = IO.for_fd(Uv.kiln_uv_fd, autoclose: false)
          start_lanes
          @pump = Thread.new { pump_thread }
          self
        end

        private

        def start_lanes
          @handlers.times do |index|
            @lanes << Queue.new
            @workers << start_worker(index)
          end
        end

        def pump_thread
          Thread.current.report_on_exception = false
          rc = Uv.kiln_uv_sigpipe_enter
          raise IOError, "cannot block SIGPIPE on event thread (#{rc})" unless rc.zero?

          begin
            pump
          ensure
            Uv.kiln_uv_sigpipe_leave
          end
        end

        def open_listeners
          rc = Uv.kiln_uv_configure(@settings, @settings.size)
          raise IOError, "kiln event server setup failed: #{Uv.kiln_uv_error_text(rc)} (#{rc})" unless rc.zero?

          start_listening
          @ports = Array.new(@listen.size) { |index| Uv.kiln_uv_port(index) }
          @port = Kiln::Runtime.first_port(@ports)
        end

        def start_listening
          started = false
          begin
            @listen.each { |spec| adopt(spec) }
            rc = Uv.kiln_uv_start
            raise IOError, "kiln event server listen failed: #{Uv.kiln_uv_error_text(rc)} (#{rc})" unless rc.zero?

            started = true
          ensure
            abandon_listen unless started
          end
        end

        def abandon_listen
          Uv.kiln_uv_abandon
          release_listeners
        end

        def adopt(spec)
          fd = spec.open(@settings[9], @reuse_port)
          @owned_paths << Transport::Sock.own_path(spec.path) if spec.owns_path?
          tls = spec.tls
          context = tls.nil? ? -1 : tls.context
          index = Uv.kiln_uv_adopt(fd, context)
          return unless index.negative?

          Transport::Sock.kiln_sock_close(fd) if spec.kind != :fd
          raise IOError, "kiln event server cannot use #{spec}: #{Uv.kiln_uv_error_text(index)} (#{index})"
        end

        def release_listeners
          @owned_paths.each { |record| Transport::Sock.unlink_owned(record) }
          @owned_paths.clear
          @listen.each { |spec| spec.tls&.release }
        end
      end

      module Stopping
        def shutdown(grace: 5.0)
          check_rules([['shutdown grace', grace, :seconds_at_least]])
          return 0 if @stopped || @pump.nil?

          begin_drain
          await_quiet(Kiln::Runtime.now + grace)
          left = @quiet ? 0 : cut_off
          stop_all(left.zero? ? 0.5 : 0)
          left + @aborted_taken + @aborted_count
        end

        private

        def begin_drain
          @stopped = true
          @quiet = false
          @draining = true
          wake_pump
        end

        def await_quiet(limit)
          Kernel.sleep 0.01 until @quiet || !@pump.alive? || Kiln::Runtime.now >= limit
        end

        def cut_off
          @cutoff = true
          return @inflight unless @handlers.positive?

          wake_pump
          ready_limit = Kiln::Runtime.now + 0.5
          Kernel.sleep 0.001 until @dispatch_ready || !@pump.alive? || Kiln::Runtime.now >= ready_limit
          @inflight
        end

        def stop_all(pause)
          @lanes.each(&:close)
          @stop = true
          wake_pump
          threads = @worker_lock.synchronize { @workers + @retired }
          stop_threads(threads, Kiln::Runtime.now + pause)
          wake_pump
          stop_pump(Kiln::Runtime.now + pause)
          release_listeners
        end

        def stop_threads(threads, deadline)
          threads.each do |thread|
            wait_dead(thread, deadline)
            thread.kill if thread.alive?
            wait_dead(thread, Kiln::Runtime.now + 1.0)
            next if thread.alive?

            join_or_log(thread)
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
          wait_dead(thread, Kiln::Runtime.now + 1.0)
          return if thread.alive?

          join_or_log(thread)
        end

        def wait_dead(thread, deadline)
          Kernel.sleep 0.01 while thread.alive? && Kiln::Runtime.now < deadline
        end

        def join_or_log(thread)
          thread.join
        rescue StandardError => e
          @log.error("event server thread stopped with #{e.class}: #{e.message}")
        end
      end

      module Pumping
        private

        def pump
          scan = Array.new(HTTP::Native::CAP, 0)
          meta = Array.new(META, 0)
          drained = false
          drained = pump_round(scan, meta, drained) until @stop && workers_stopped?
          drain_done
          Uv.kiln_uv_flush
          Uv.kiln_uv_poll
        ensure
          pump_teardown
        end

        def pump_round(scan, meta, drained)
          drained = start_drain(drained)
          Uv.kiln_uv_poll
          handled = pump_events + take_requests(scan, meta)
          @dispatch_ready = true if @cutoff
          Uv.kiln_uv_flush
          @quiet = drained && @inflight.zero? && Uv.kiln_uv_busy.zero?
          idle(drained) if handled.zero?
          drained
        rescue Runtime::DeadlineExceeded
          drained
        end

        def idle(drained)
          park(drained ? 0.01 : handler_wait) if Uv.kiln_uv_settle.zero?
        end

        def start_drain(drained)
          return drained if drained || !@draining

          Uv.kiln_uv_drain
          @inlets.each_value(&:nudge)
          true
        end

        def pump_events
          handled = drain_done + pump_streams + expire_handlers
          handled += pump_inlets unless @inlets.empty?
          handled += expire_uploads unless @uploads.empty?
          handled
        end

        def take_requests(scan, meta)
          handled = 0
          loop do
            src = Uv.kiln_uv_next(scan, HTTP::Native::CAP, meta)
            break if src.empty?

            take_request(src, scan, meta)
            handled += 1
          end
          handled
        end

        def take_request(src, scan, meta)
          return serve(src, scan, meta) unless @cutoff

          Uv.kiln_uv_abort(meta[3], meta[4])
          @aborted_taken += 1
        end

        def pump_teardown
          halt_streams
          stop_workers_now
        ensure
          close_uv
        end

        def halt_streams
          @outlets.each_value(&:halt)
          @inlets.each_value(&:halt)
          @uploads.each_value { |job| job.thread&.kill }
        end

        def stop_workers_now
          @wake_lock.synchronize { @pump_stopping = true }
          @lanes.each(&:close)
          @workers.each(&:kill)
          @retired.each(&:kill)
          Kernel.sleep 0.01 until workers_stopped?
        end

        def close_uv
          @wake_lock.synchronize { stop_uv unless @uv_closed }
        end

        def stop_uv
          Uv.kiln_uv_stop
          @aborted_count = Uv.kiln_uv_aborted
          @uv_closed = true
        end
      end

      module Waking
        private

        def park(timeout)
          timeout = libuv_bound(timeout)
          @wake_lock.synchronize do
            @parked = true
            @wake_at = Kiln::Runtime.now + timeout
          end
          @poller.wait_readable(timeout) if idle_pump?
        ensure
          @wake_lock.synchronize { @parked = false }
        end

        def libuv_bound(timeout)
          uv_timeout = Uv.kiln_uv_timeout
          libuv_wait = uv_timeout * 0.001
          uv_timeout >= 0 && libuv_wait < timeout ? libuv_wait : timeout
        end

        def idle_pump? = @done.empty? && @ready.empty? && (@inlets.empty? || @wants.empty?)

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

        def handler_wait
          now = Kiln::Runtime.now
          wait = active_wait(now, HANDLER_WAIT)
          return wait if wait <= 0 || @uploads.empty?

          upload_wait(now, wait)
        end

        def active_wait(now, wait)
          index = 0
          while index < @handlers
            job = @active_locks[index].synchronize { @active[index] }
            wait = [wait, job[0].deadline - now].min if job
            return 0 if wait <= 0

            index += 1
          end
          wait
        end

        def upload_wait(now, wait)
          @uploads.each_value do |upload|
            wait = [wait, upload.ctx.deadline - now].min
            return 0 if wait <= 0
          end
          wait
        end
      end

      module Workers
        private

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

        def expire_handlers
          now = Kiln::Runtime.now
          expired = 0
          index = 0
          while index < @handlers
            job = take_expired(index, now)
            expired += expire_job(index, job) if job
            index += 1
          end
          expired
        end

        def take_expired(index, now)
          @active_locks[index].synchronize do
            current = @active[index]
            if current && current[0].deadline <= now
              @active[index] = nil
              current
            end
          end
        end

        def expire_job(index, job)
          replace_worker(index)
          ctx, slot, gen = job
          @done << [timed_out(ctx), slot, gen]
          @killed += 1
          1
        end

        def replace_worker(index)
          @worker_lock.synchronize do
            worker = @workers[index]
            worker.kill if worker.alive?
            @retired = living(@retired)
            @retired << worker
            @workers[index] = start_worker(index) unless @stop
          end
        end

        def expire_uploads
          now = Kiln::Runtime.now
          expired = 0
          @uploads.each_value do |job|
            next unless job.ctx.deadline <= now && job.claim!

            expire_upload(job)
            expired += 1
          end
          expired
        end

        def expire_upload(job)
          job.thread&.kill
          @uploads.delete(job.slot)
          @done << [timed_out(job.ctx), job.slot, job.gen]
          @killed += 1
        end

        def timed_out(ctx)
          timed = Routing::Context.new(ctx.req, HTTP::Response.new, ctx.app, ctx.id, ctx.deadline)
          timed.res.text(DEADLINE_BODY, status: 504)
          timed
        end

        def work(lane, index)
          while (job = lane.pop)
            break unless job_finished?(job, index)

            @done << job
            nudge_pump
          end
        end

        def job_finished?(job, index)
          @active_locks[index].synchronize { @active[index] = job }
          ctx = job[0]
          nudge_pump(ctx.deadline)
          run(ctx) if Kiln::Runtime.now < ctx.deadline
          job[0] = fallback_context(ctx, 504, DEADLINE_BODY) if Kiln::Runtime.now >= ctx.deadline
          release_active?(job, index)
        end

        def release_active?(job, index)
          @active_locks[index].synchronize do
            if @active[index].equal?(job)
              @active[index] = nil
              true
            else
              false
            end
          end
        end
      end

      module Intake
        private

        def serve(src, scan, meta)
          parsed = HTTP::Native.build(src, meta[0], scan)
          return reply_bad(meta) if parsed.nil?

          version, verb, target, headers = parsed
          target, status = check_event_head(version, verb, target, headers)
          return reply_bad(meta) if status == 400
          return reply_error(meta, status, version) if status.positive?

          parsed[2] = target
          route_context(new_context(build_request(src, meta, parsed)), meta)
        end

        def new_context(req)
          @seq += 1
          @inflight += 1
          Routing::Context.new(req, HTTP::Response.new, @app, @seq, Kiln::Runtime.now + @request_timeout)
        end

        def route_context(ctx, meta)
          slot = meta[3]
          gen = meta[4]
          if @handlers.positive?
            @lanes[slot % @handlers] << [ctx, slot, gen]
            return 0
          end
          return spawn_upload(ctx, slot, gen) if meta[5].anybits?(STREAMED)

          run_inline(ctx, slot, gen)
        end

        def run_inline(ctx, slot, gen)
          run_marked(ctx)
          ctx = fallback_context(ctx, 504, DEADLINE_BODY) if Kiln::Runtime.now >= ctx.deadline
          deliver(ctx, slot, gen)
        ensure
          @inflight -= 1
        end

        def run_marked(ctx)
          @wake_lock.synchronize { @inline_busy = true }
          Thread.current[:kiln_inline] = true
          run(ctx)
        ensure
          Thread.current[:kiln_inline] = nil
          @wake_lock.synchronize { @inline_busy = false }
        end

        def check_event_head(version, verb, target, headers)
          return [nil, 501] if verb == 'CONNECT'

          absolute = target.match?(HTTP::Syntax::ABSOLUTE_FORM)
          return [nil, 400] unless event_target?(verb, target, absolute)
          return [nil, 400] unless event_host?(version, headers['host'], absolute)
          return [target, 0] unless absolute

          target, authority = HTTP::Syntax.absolute_target(target)
          return [nil, 400] unless target

          headers['host'] = authority
          [target, 0]
        end

        def event_target?(verb, target, absolute)
          return verb == 'OPTIONS' if target == '*'

          target.start_with?('/') || absolute
        end

        def event_host?(version, host, absolute)
          return false if version == '1.1' && (host.nil? || (!absolute && host.empty?))

          host.nil? || host.empty? || HTTP::Native.host?(host)
        end

        def reply_error(meta, status, version)
          _code, message = HTTP::Syntax::ERRORS.fetch(:not_implemented)
          body = "#{message}\n".b
          response = HTTP::Response.new
          response.text(body, status: status)
          head = HTTP::Response.build_head(status, response.headers, body.bytesize, false, version: version)
          Uv.kiln_uv_send(meta[3], meta[4], head, head.bytesize, body, body.bytesize, 1)
        end

        def reply_bad(meta)
          Uv.kiln_uv_send(meta[3], meta[4], BAD_REQUEST, BAD_REQUEST.bytesize, EMPTY_BODY, 0, 1)
        end
      end

      module Requests
        private

        def build_request(src, meta, head)
          version, verb, target, headers = head
          flags = meta[5]
          alpn = flags.anybits?(TLS_FLAG) ? Uv.kiln_uv_tls_alpn(meta[3], meta[4]) : nil
          payload = flags.anybits?(STREAMED) ? request_inlet(meta) : nil
          body = payload ? EMPTY_BODY : inline_body(src, meta)
          HTTP::Request.new(verb, target, headers, body, HTTP::Request::Wire.new(version, payload, alpn))
        end

        def request_inlet(meta)
          slot = meta[3]
          inlet = Transport::Inlet.new(self, slot, meta[4], @read_timeout)
          @inlets[slot] = inlet
          declared = meta[6]
          HTTP::Payload.new(inlet, declared.negative? ? nil : declared, @max_body)
        end

        def inline_body(src, meta)
          length = meta[2]
          length.positive? ? src.byteslice(meta[1], length) : EMPTY_BODY
        end

        def spawn_upload(ctx, slot, gen)
          job = Job.new(ctx, slot, gen, nil, false, Mutex.new)
          @uploads[slot] = job
          job.thread = Thread.new { run_upload(job) }
          0
        end

        def run_upload(job)
          Thread.current.report_on_exception = false
          ctx = job.ctx
          run(ctx) if Kiln::Runtime.now < ctx.deadline
          return unless job.claim!

          @done << [finished_context(ctx), job.slot, job.gen]
          nudge_pump
        end

        def finished_context(ctx)
          Kiln::Runtime.now >= ctx.deadline ? fallback_context(ctx, 504, DEADLINE_BODY) : ctx
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

        def dispatch(ctx)
          @handler.call(ctx)
        rescue Runtime::ClientGone
          ctx.gone = true
        rescue *Kiln::Runtime::FAILURES => e
          reply = Kiln::Runtime.timeout_reply(e)
          unless reply
            @log.error("#{e.class}: #{e.message}")
            reply = ["internal error\n", 500]
          end
          Kiln::Runtime.apply_reply(ctx, reply)
        end

        def fallback_context(ctx, status, body)
          response = HTTP::Response.new
          response.text(body, status:)
          fallback = Routing::Context.new(ctx.req, response, ctx.app, ctx.id, ctx.deadline)
          fallback.gone = ctx.gone
          fallback
        end
      end

      module Delivery
        private

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

        def settle_body(ctx, slot, gen)
          return 0 if @inlets.empty?

          drop_inlet(slot, gen)
          req = ctx.req
          return 0 unless req.streamed?

          Uv.kiln_uv_body_finish(slot, gen, req.payload.failed? ? 1 : 0)
        end

        def drop_inlet(slot, gen)
          inlet = @inlets[slot]
          return unless inlet && inlet.gen == gen

          @inlets.delete(slot)
          @thirsty.delete(slot)
          inlet.halt
        end

        def deliver(ctx, slot, gen)
          outlet = @outlets[slot]
          return outlet.hold_back(ctx) if outlet && outlet.gen == gen

          unread = settle_body(ctx, slot, gen)
          return Uv.kiln_uv_send(slot, gen, EMPTY_BODY, 0, EMPTY_BODY, 0, 1) if ctx.gone

          res = ctx.res
          return open_tunnel(ctx, slot, gen) if HTTP::Response.tunnels?(res)

          keep = keep_open?(ctx.req, slot, gen, unread)
          return open_stream(ctx, slot, gen, keep) if HTTP::Response.streams?(res)

          send_fixed(ctx, slot, gen, keep)
        end

        def keep_open?(req, slot, gen, unread)
          unread.zero? && HTTP::Syntax.persistent?(req.http_version, req.headers['connection']) &&
            Uv.kiln_uv_closes_after(slot, gen, @draining ? 1 : 0).zero?
        end

        def send_fixed(ctx, slot, gen, keep)
          req = ctx.req
          res = ctx.res
          raw_status = res.status
          payload = HTTP::Response.payload(raw_status, res.body)
          head = HTTP::Response.build_head(raw_status, res.headers, payload.bytesize, keep, version: req.http_version)
          payload = EMPTY_BODY if req.verb == HEAD || HTTP::Response.no_body?(raw_status)
          Uv.kiln_uv_send(slot, gen, head, head.bytesize, payload, payload.bytesize, keep ? 0 : 1)
        end
      end

      module Outgoing
        private

        def open_tunnel(ctx, slot, gen)
          refusal = stream_refusal
          return deliver(fallback_context(ctx, 503, refusal), slot, gen) if refusal

          head = ctx.res.upgrade_head
          return Uv.kiln_uv_abort(slot, gen) if Uv.kiln_uv_tunnel(slot, gen, head, head.bytesize).negative?

          start_tunnel(ctx, Outlet.new(self, slot, gen, false, false))
        end

        def stream_refusal
          return "too many streams\n" if @outlets.size >= @max_streams
          return "shutting down\n" if @draining

          nil
        end

        def start_tunnel(ctx, outlet)
          slot = outlet.slot
          outlet.tunnel = true
          inlet = Transport::Inlet.new(self, slot, outlet.gen, @read_timeout)
          @inlets[slot] = inlet
          @outlets[slot] = outlet
          @inflight += 1
          body = ctx.res.tunnel_body
          id = ctx.id
          outlet.thread = Thread.new { run_tunnel(outlet, inlet, body, id) }
          0
        end

        def run_tunnel(outlet, inlet, body, id)
          Thread.current[:request_id] = id
          failed = true
          body.call(Transport::Tunnel.new(inlet, outlet, @write_timeout))
          failed = false
        rescue Runtime::ClientGone
          nil
        rescue *Kiln::Runtime::FAILURES => e
          @log.error("upgrade #{e.class}: #{e.message}")
        ensure
          outlet.complete(failed)
        end

        def open_stream(ctx, slot, gen, keep)
          req = ctx.req
          res = ctx.res
          chunked, keep = HTTP::Response.stream_framing(res, req.http_version, keep)
          head = stream_head(req, res, keep)
          return send_head_only(slot, gen, head, keep) if req.verb == HEAD
          return deliver(fallback_context(ctx, 503, "too many streams\n"), slot, gen) if @outlets.size >= @max_streams
          return -1 if Uv.kiln_uv_part(slot, gen, head, head.bytesize).negative?

          spawn_stream(ctx, Outlet.new(self, slot, gen, keep, chunked))
        end

        def send_head_only(slot, gen, head, keep)
          Uv.kiln_uv_send(slot, gen, head, head.bytesize, EMPTY_BODY, 0, keep ? 0 : 1)
        end

        def stream_head(req, res, keep)
          size = HTTP::Response.stream_size(res.stream_length)
          HTTP::Response.build_head(res.status, res.headers, size, keep, version: req.http_version)
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
          stream_into(outlet, body, length)
          failed = false
        rescue Runtime::ClientGone
          nil
        rescue *Kiln::Runtime::FAILURES => e
          @log.error("stream #{e.class}: #{e.message}")
        ensure
          outlet.complete(failed)
        end

        def stream_into(outlet, body, length)
          out = stream_writer(outlet, length)
          body.call(out)
          out.flush
          out.verify!
          outlet.ending = out.ending
        end

        def stream_writer(outlet, length)
          timeout = @write_timeout
          sink = ->(prefix, bytes) { outlet.enqueue(prefix, bytes, Kiln::Runtime.now + timeout) }
          HTTP::Stream.new(sink, -> { outlet.closed? }, outlet.chunked, length)
        end
      end

      module Streams
        private

        def pump_inlets
          collect_wants
          return 0 if @thirsty.empty?

          count = 0
          @thirsty.each_value { |inlet| count += 1 if feed_inlet?(inlet) }
          count
        end

        def collect_wants
          until @wants.empty?
            inlet = @wants.pop
            @thirsty[inlet.slot] = inlet if @inlets[inlet.slot].equal?(inlet)
          end
        end

        def feed_inlet?(inlet)
          data = Uv.kiln_uv_body_take(inlet.slot, inlet.gen, inlet.want, @take_state)
          state = @take_state[0]
          return false if state == TAKE_WAIT

          @thirsty.delete(inlet.slot)
          hand_inlet(inlet, state, data)
          true
        end

        def hand_inlet(inlet, state, data)
          case state
          when TAKE_DATA then inlet.offer(data)
          when TAKE_EOF then inlet.finish
          else inlet.fail_with(state)
          end
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
          now = Kiln::Runtime.now
          sweep = now >= @liveness_at
          @liveness_at = now + LIVENESS_EVERY if sweep
          targets = sweep ? @outlets : @backlogged
          return if targets.empty?

          targets.each_value { |outlet| note_backlog(outlet, Uv.kiln_uv_backlog(outlet.slot, outlet.gen)) }
        end

        def close_stream(outlet, failed)
          slot = outlet.slot
          @outlets.delete(slot)
          @backlogged.delete(slot)
          @inflight -= 1
          return close_tunnel(outlet) if outlet.tunnel

          broken = failed || outlet.gone?
          send_ending(outlet, broken)
          outlet.deferred&.each { |ctx| deliver(ctx, slot, outlet.gen) } unless broken
        end

        def close_tunnel(outlet)
          slot = outlet.slot
          gen = outlet.gen
          drop_inlet(slot, gen)
          Uv.kiln_uv_end(slot, gen)
        end

        def send_ending(outlet, broken)
          slot = outlet.slot
          gen = outlet.gen
          return Uv.kiln_uv_abort(slot, gen) if broken

          ending = outlet.ending
          Uv.kiln_uv_send(slot, gen, EMPTY_BODY, 0, ending, ending.bytesize, outlet.keep ? 0 : 1)
        end
      end

      include Setup
      include Lifecycle
      include Stopping
      include Pumping
      include Waking
      include Workers
      include Intake
      include Requests
      include Delivery
      include Outgoing
      include Streams

      attr_reader :port, :killed, :ports

      def initialize(config, app = nil, **options)
        config = event_options(config, app, options) unless config.is_a?(EventOptions)
        init_wiring(config)
        init_limits(config)
        init_settings(config)
        init_streams
        init_workers(config.handlers)
        init_wake
        init_flags
        init_counters
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
    end

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

    private_constant :Event, :Outlet
  end
end
