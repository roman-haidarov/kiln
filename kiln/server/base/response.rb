module Kiln
  class Server
    class Base
      module Serving
        private

        def serve(req, slot, deadline, id, box)
          current = Thread.current
          enter_request(current, id, deadline, slot.sock.fileno)
          ctx = Routing::Context.new(req, HTTP::Response.new, @app, id, deadline)
          dispatch(ctx)
          respond_after(ctx, slot, box, claim_write(slot))
        ensure
          leave_request(current, slot)
        end

        def enter_request(current, id, deadline, socket_fd)
          current[:request_id] = id
          current[:kiln_deadline] = deadline
          current[:kiln_fd] = socket_fd
        end

        def claim_write(slot)
          shard = slot.shard
          @shard_locks[shard].synchronize do
            if slot.state == :reaping
              :reaped
            elsif Kiln::Runtime.now > slot.deadline + @kill_grace
              mark_late(slot, shard)
            else
              start_writing(slot)
            end
          end
        end

        def mark_late(slot, shard)
          unhandle(slot)
          slot.state = :reaping
          @late[shard] += 1
          :late
        end

        def start_writing(slot)
          slot.state = :writing
          unhandle(slot)
          :write
        end

        def respond_after(ctx, slot, box, verdict)
          sock = slot.sock
          return write_late(sock, box) if verdict == :late
          return false unless verdict == :write && !ctx.gone

          req = ctx.req
          settled = settle_body(req)
          kept = write_response(sock, req, ctx.res, box, settled)
          linger(sock) unless settled
          kept
        end

        def write_late(sock, box)
          late_deadline = Kiln::Runtime.now + 0.5
          write_all(sock, TIMEOUT_RESPONSE, late_deadline) if flush_outbox(sock, box, late_deadline)
          nil
        end

        def leave_request(current, slot)
          current[:request_id] = nil
          current[:kiln_deadline] = nil
          current[:kiln_fd] = nil
          @shard_locks[slot.shard].synchronize { release_slot(slot) }
        end

        def release_slot(slot)
          slot.state = :idle unless slot.state == :reaping
          unhandle(slot)
          return unless slot.flying

          slot.flying = false
          @in_flight[slot.shard] -= 1
        end

        def begin_handling(slot, deadline)
          shard = slot.shard
          @shard_locks[shard].synchronize do
            start_handling(slot, deadline) if handling_open?(slot, shard)
          end
        end

        def handling_open?(slot, shard)
          !(@draining || @shut_by_shard[shard] || slot.done || slot.state == :reaping)
        end

        def start_handling(slot, deadline)
          shard = slot.shard
          slot.flying = true
          slot.deadline = deadline
          slot.state = :handling
          heap_push(slot)
          signal_reaper if slot.hidx.zero?
          @in_flight[shard] += 1
          @seq[shard] += @shard_count
        end

        def dispatch(ctx)
          @handler.call(ctx)
        rescue Runtime::ClientGone
          ctx.gone = true
        rescue *Kiln::Runtime::FAILURES => e
          Kiln::Runtime.dispatch_failure(@log, ctx, e)
        end
      end

      module Writing
        private

        def settle_body(req)
          return true unless req.streamed?

          payload = req.payload
          return true if payload.complete?
          return false if payload.failed? || payload.source.expect

          drain_payload?(payload)
        rescue StandardError
          false
        end

        def drain_payload?(payload)
          left = payload.remaining
          return false if left.nil? || left > DRAIN_MAX

          payload.discard
          true
        end

        def write_response(sock, req, res, box, settled)
          return write_tunnel(sock, res, box) if HTTP::Response.tunnels?(res)

          keep = keep_alive?(req, settled)
          return write_stream(sock, req, res, box, keep) if HTTP::Response.streams?(res)

          head, body = fixed_wire(req, res, keep)
          send_fixed(sock, box, head, body, keep)
        end

        def keep_alive?(req, settled)
          settled && @keep_alive && !@draining && HTTP::Syntax.persistent?(req.http_version, req.headers['connection'])
        end

        def fixed_wire(req, res, keep)
          raw_status = res.status
          body = HTTP::Response.payload(raw_status, res.body)
          head = HTTP::Response.build_head(raw_status, res.headers, body.bytesize, keep, version: req.http_version)
          status = HTTP::Response.valid_status?(raw_status) ? raw_status : 500
          body = EMPTY_BODY if req.verb == 'HEAD' || HTTP::Response.no_body?(status)
          [head, body]
        end

        def send_fixed(sock, box, head, body, keep)
          size = head.bytesize + body.bytesize
          return box.push(head, body) if queue?(box, size, keep)

          limit = Kiln::Runtime.now + @write_timeout
          return false unless box.empty? || flush_outbox(sock, box, limit)
          return box.push(head, body) if queue?(box, size, keep)

          sent = write_all(sock, head, limit, body)
          keep && sent
        end

        def queue?(box, size, keep) = keep && box.fits?(size)

        def write_tunnel(sock, res, box)
          return false unless tunnel_head_sent?(sock, res, box)

          Thread.current[:kiln_deadline] = nil
          res.tunnel_body.call(tunnel_conn(sock, box.buffer))
          false
        rescue Runtime::ClientGone
          false
        rescue *Kiln::Runtime::FAILURES => e
          @log.error("upgrade #{e.class}: #{e.message}")
          false
        end

        def tunnel_head_sent?(sock, res, box)
          limit = Kiln::Runtime.now + @write_timeout
          return false unless flush_outbox(sock, box, limit)

          head = res.upgrade_head
          head.empty? || write_all(sock, head, limit)
        end

        def tunnel_conn(sock, buf)
          timeout = @write_timeout
          writer = ->(bytes) { write_all(sock, bytes, Kiln::Runtime.now + timeout) }
          Transport::SocketConn.new(sock, buf, writer, -> { @draining })
        end
      end

      module Streaming
        private

        def write_stream(sock, req, res, box, keep)
          version = req.http_version
          chunked, keep = HTTP::Response.stream_framing(res, version, keep)
          limit = Kiln::Runtime.now + @write_timeout
          return false unless flush_outbox(sock, box, limit)

          size = HTTP::Response.stream_size(res.stream_length)
          head = HTTP::Response.build_head(res.status, res.headers, size, keep, version:)
          return false unless write_all(sock, head, limit)
          return keep if req.verb == 'HEAD'

          stream_body(sock, res, chunked) && keep
        end

        def stream_body(sock, res, chunked)
          Thread.current[:kiln_deadline] = nil
          out = socket_writer(sock, chunked, res.stream_length)
          res.stream_body.call(out)
          finish_stream(sock, out, chunked)
        rescue Runtime::ClientGone
          false
        rescue *Kiln::Runtime::FAILURES => e
          @log.error("stream #{e.class}: #{e.message}")
          false
        end

        def finish_stream(sock, out, chunked)
          out.flush
          out.verify!
          !chunked || write_all(sock, out.ending, Kiln::Runtime.now + @write_timeout)
        end

        def socket_writer(sock, chunked, length)
          timeout = @write_timeout
          push = lambda do |prefix, bytes|
            sent = write_all(sock, prefix, Kiln::Runtime.now + timeout, bytes)
            raise Runtime::ClientGone, 'stream write failed' unless sent
          end
          HTTP::Stream.new(push, -> { @draining || Kiln::Runtime.client_gone? }, chunked, length)
        end
      end

      include Serving
      include Writing
      include Streaming
    end
  end
end
