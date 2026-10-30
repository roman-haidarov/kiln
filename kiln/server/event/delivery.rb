module Kiln
  class Server
    class Event
      module Stalling
        private

        def promote_stalled
          ready = @stalled.keys.select { |key| drained?(key) }
          ready.each { |key| promote_drained(key) }
          ready.length
        rescue ClosedQueueError
          0
        end

        def drained?(key)
          slot, gen = @stalled[key]
          @uv.kiln_uv_backlog(slot, gen) < OUT_LOW
        end

        def promote_drained(key)
          slot, gen = @stalled[key]
          @stalled.delete(key)
          promote_connection(gen, slot)
        end
      end

      module Delivery
        private

        def drain_done
          count = 0
          while (item = @done.pop(timeout: 0))
            finish_item(item)
            count += 1
          end
          count
        end

        def finish_item(item)
          ctx = item.ctx
          slot = item.slot
          gen = item.gen
          forget_upload(slot, gen) unless @uploads.empty?
          deliver(ctx, slot, gen)
          promote_connection(gen, slot)
          @inflight -= 1
          release_held(slot, gen) unless @held.empty?
        end

        def release_held(slot, gen)
          held = @held.delete((gen * 65_536) + slot)
          return unless held

          deliver(held[0], slot, gen)
          @inflight -= 1
        end

        def promote_connection(gen, slot)
          key = (gen * 65_536) + slot
          waiting = @busy[key]
          return unless waiting

          backlog = @uv.kiln_uv_backlog(slot, gen)
          return discard_waiting(key, slot, gen, waiting) if backlog.negative?
          return @stalled[key] = [slot, gen] if !waiting.empty? && backlog >= OUT_HIGH

          promote_waiting(key, waiting)
        rescue ClosedQueueError
          nil
        end

        def discard_waiting(key, slot, gen, waiting)
          @inflight -= waiting.length
          @busy.delete(key)
          @stalled.delete(key)
          drop_inlet(slot, gen) unless @inlets.empty?
        end

        def promote_waiting(key, waiting)
          if @jobs.closed?
            @busy.delete(key)
            return
          end

          job = waiting.shift
          if job
            @jobs << job
          else
            @busy.delete(key)
          end
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

          @uv.kiln_uv_body_finish(slot, gen, req.payload.failed? ? 1 : 0)
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
          return @uv.kiln_uv_send(slot, gen, EMPTY_BODY, 0, EMPTY_BODY, 0, 1) if ctx.gone

          res = ctx.res
          return open_tunnel(ctx, slot, gen) if HTTP::Response.tunnels?(res)

          keep = keep_open?(ctx.req, slot, gen, unread)
          return open_stream(ctx, slot, gen, keep) if HTTP::Response.streams?(res)

          send_fixed(ctx, slot, gen, keep)
        end

        def keep_open?(req, slot, gen, unread)
          unread.zero? && HTTP::Syntax.persistent?(req.http_version, req.headers['connection']) &&
            @uv.kiln_uv_closes_after(slot, gen, @draining ? 1 : 0).zero?
        end

        def send_fixed(ctx, slot, gen, keep)
          req = ctx.req
          res = ctx.res
          status = res.status
          payload = HTTP::Response.payload(status, res.body)
          head = HTTP::Response.build_head(status, res.headers, payload.bytesize, keep, version: req.http_version)
          payload = HTTP::Response.body_for(req.verb, status, payload)
          @uv.kiln_uv_send(slot, gen, head, head.bytesize, payload, payload.bytesize, keep ? 0 : 1)
        end
      end

    end
  end
end
