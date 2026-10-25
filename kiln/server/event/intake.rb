module Kiln
  class Server
    class Event
      module Intake
        private

        def serve(src, scan, meta)
          parsed = HTTP::Native.build(src, meta[0], scan)
          return refuse(meta, '1.1', 400) if parsed.nil?

          version, verb, target, headers = parsed
          target, status = check_event_head(version, verb, target, headers)
          return refuse(meta, version, status) if status.positive?

          parsed[2] = target
          route_context(new_context(build_request(src, meta, parsed)), meta)
        end

        def new_context(req)
          @seq += 1
          @inflight += 1
          Routing::Context.new(req, HTTP::Response.new, @seq, Kiln::Runtime.now + @request_timeout)
        end

        def route_context(ctx, meta)
          slot = meta[3]
          gen = meta[4]
          return enqueue_context(ctx, slot, gen) if @handlers.positive?
          return spawn_upload(ctx, slot, gen) if meta[5].anybits?(STREAMED)

          run_inline(ctx, slot, gen)
        end

        def enqueue_context(ctx, slot, gen)
          key = (gen * 65_536) + slot
          if @busy[key]
            @busy[key] << Dispatch.new(ctx, slot, gen)
          else
            @busy[key] = []
            @jobs << Dispatch.new(ctx, slot, gen)
          end
          0
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
          problem = HTTP::RequestPolicy.head_problem(version, verb, target, headers)
          return [nil, HTTP::Syntax.error_tuple(problem)[1]] if problem

          origin = HTTP::RequestPolicy.origin(target, headers)
          origin ? [origin, 0] : [nil, 400]
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

      module Refusals
        private

        def refuse(meta, version, status)
          slot = meta[3]
          gen = meta[4]
          Uv.kiln_uv_refuse(slot, gen)
          unless conn_busy?(slot, gen)
            return reply_bad(meta) if status == 400

            return reply_error(meta, status, version)
          end
          route_refusal(refusal_context(version, status), slot, gen)
        end

        def conn_busy?(slot, gen)
          return true if @busy.key?((gen * 65_536) + slot)

          outlet = @outlets[slot]
          return true if outlet && outlet.gen == gen

          upload = @uploads[slot]
          !upload.nil? && upload.gen == gen
        end

        def refusal_context(version, status)
          body = status == 400 ? "bad request\n" : "#{HTTP::Syntax::ERRORS.fetch(:not_implemented)[1]}\n"
          wire = HTTP::Request::Wire.new(version, nil, nil)
          ctx = new_context(HTTP::Request.new('GET', '/', { 'connection' => 'close' }, EMPTY_BODY, wire))
          ctx.res.text(body.b, status: status)
          ctx.prepared = true
          ctx
        end

        def route_refusal(ctx, slot, gen)
          return enqueue_context(ctx, slot, gen) if @handlers.positive?

          upload = @uploads[slot]
          if upload && upload.gen == gen
            @held[(gen * 65_536) + slot] = [ctx]
            return 0
          end
          deliver(ctx, slot, gen)
          @inflight -= 1
          0
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

          @done << Dispatch.new(finished_context(ctx), job.slot, job.gen)
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
            @log&.error("#{e.class}: #{e.message}")
            reply = ["internal error\n", 500]
          end
          Kiln::Runtime.apply_reply(ctx, reply)
        end

        def fallback_context(ctx, status, body)
          response = HTTP::Response.new
          response.text(body, status:)
          fallback = Routing::Context.new(ctx.req, response, ctx.id, ctx.deadline)
          fallback.gone = ctx.gone
          fallback
        end
      end

    end
  end
end
