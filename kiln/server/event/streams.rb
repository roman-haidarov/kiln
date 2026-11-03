module Kiln
  class Server
    class Event
      private

      def open_tunnel(ctx, slot, gen)
        refusal = stream_refusal
        return deliver(fallback_context(ctx, 503, refusal), slot, gen) if refusal

        head = ctx.res.upgrade_head
        if @uv.kiln_uv_tunnel(slot, gen, head, head.bytesize).negative?
          unreserve_stream
          return @uv.kiln_uv_abort(slot, gen)
        end

        start_tunnel(ctx, Outlet.new(self, slot, gen, false, false))
      end

      def reserve_stream
        return Uv.kiln_uv_group_reserve(@group, @max_streams) == 1 if @group.positive?
        return false if @stream_count >= @max_streams

        @stream_count += 1
        true
      end

      def unreserve_stream
        if @group.positive?
          Uv.kiln_uv_group_streams(@group, -1)
        else
          @stream_count -= 1
        end
      end

      def track_stream(slot, outlet)
        replaced = @outlets[slot]
        halt_outlet(replaced) if replaced && !replaced.equal?(outlet)
        outlet.reserved = true
        @streams[outlet.gen] = outlet
        @outlets[slot] = outlet
      end

      def untrack_stream(outlet)
        @outlets.delete(outlet.slot) if @outlets[outlet.slot].equal?(outlet)
        @streams.delete(outlet.gen)
        free_reservation(outlet)
      end

      def halt_outlet(outlet)
        drop_inlet(outlet.slot, outlet.gen) if outlet.tunnel
        outlet.halt
      end

      def free_reservation(outlet)
        return unless outlet.reserved

        outlet.reserved = false
        unreserve_stream
      end

      def stream_refusal
        return "shutting down\n" if @draining
        return "too many streams\n" unless reserve_stream

        nil
      end

      def start_tunnel(ctx, outlet)
        slot = outlet.slot
        outlet.tunnel = true
        inlet = Transport::Inlet.new(self, slot, outlet.gen, @read_timeout)
        @inlets[slot] = inlet
        track_stream(slot, outlet)
        @inflight += 1
        res = ctx.res
        body = res.tunnel_body
        idle = res.tunnel_idle
        id = ctx.id
        outlet.thread = Thread.new { run_tunnel(outlet, inlet, body, idle, id) }
        0
      end

      def run_tunnel(outlet, inlet, body, idle, id)
        Thread.current[:request_id] = id
        failed = true
        body.call(Transport::Tunnel.new(inlet, outlet, @write_timeout, idle))
        failed = false
      rescue Runtime::ClientGone
        nil
      rescue *Kiln::Runtime::FAILURES => e
        @log&.error("upgrade #{e.class}: #{e.message}")
      ensure
        outlet.complete(failed)
      end

      def open_stream(ctx, slot, gen, keep)
        req = ctx.req
        res = ctx.res
        chunked, keep = HTTP::Response.stream_framing(res, req.http_version, keep)
        head = stream_head(req, res, keep)
        return send_head_only(res, slot, gen, head, keep) if req.verb == HEAD
        return deliver(fallback_context(ctx, 503, "too many streams\n"), slot, gen) unless reserve_stream
        return unsent_stream(res) if @uv.kiln_uv_part(slot, gen, head, head.bytesize).negative?

        spawn_stream(ctx, Outlet.new(self, slot, gen, keep, chunked))
      end

      def send_head_only(res, slot, gen, head, keep)
        release_quietly(res)
        @uv.kiln_uv_send(slot, gen, head, head.bytesize, EMPTY_BODY, 0, keep ? 0 : 1)
      end

      def unsent_stream(res)
        unreserve_stream
        release_quietly(res)
        -1
      end

      def stream_head(req, res, keep)
        size = HTTP::Response.stream_size(res.stream_length)
        HTTP::Response.build_head(res.status, res.headers, size, keep, version: req.http_version)
      end

      def spawn_stream(ctx, outlet)
        outlet.response = ctx.res
        track_stream(outlet.slot, outlet)
        @inflight += 1
        res = ctx.res
        id = ctx.id
        outlet.thread = Thread.new { run_stream(outlet, res, id) }
        0
      end

      def run_stream(outlet, res, id)
        Thread.current[:request_id] = id
        failed = true
        stream_into(outlet, res.stream_body, res.stream_length)
        failed = false
      rescue Runtime::ClientGone
        nil
      rescue *Kiln::Runtime::FAILURES => e
        @log&.error("stream #{e.class}: #{e.message}")
      ensure
        begin
          release_quietly(res)
        ensure
          outlet.complete(failed)
        end
      end

      def release_quietly(res)
        Runtime.release_response(@log, res)
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
        data = @uv.kiln_uv_body_take(inlet.slot, inlet.gen, inlet.want, @take_state)
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
          next unless @streams[outlet.gen].equal?(outlet)

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
          left = @uv.kiln_uv_part(slot, gen, bytes, bytes.bytesize)
          note_backlog(outlet, left)
          break if left.negative?
        end
      end

      def note_backlog(outlet, left)
        outlet.record_backlog(left)
        halt_outlet(outlet) if left.negative? && outlet.cancellation_due?(Kiln::Runtime.now)
        if !left.zero?
          @backlogged[outlet.gen] = outlet
        else
          @backlogged.delete(outlet.gen)
        end
      end

      def refresh_backlog
        now = Kiln::Runtime.now
        sweep = now >= @liveness_at
        @liveness_at = now + LIVENESS_EVERY if sweep
        targets = sweep ? @streams : @backlogged
        return if targets.empty?

        targets.each_value { |outlet| note_backlog(outlet, @uv.kiln_uv_backlog(outlet.slot, outlet.gen)) }
      end

      def close_stream(outlet, failed)
        return unless @streams[outlet.gen].equal?(outlet)

        slot = outlet.slot
        untrack_stream(outlet)
        @backlogged.delete(outlet.gen)
        @inflight -= 1
        return close_tunnel(outlet) if outlet.tunnel

        broken = failed || outlet.gone?
        send_ending(outlet, broken)
        deferred = outlet.deferred
        return if deferred.nil?

        if broken
          deferred.each { |ctx| release_quietly(ctx.res) }
        else
          deferred.each { |ctx| deliver(ctx, slot, outlet.gen) }
        end
      end

      def close_tunnel(outlet)
        slot = outlet.slot
        gen = outlet.gen
        drop_inlet(slot, gen)
        @uv.kiln_uv_end(slot, gen)
      end

      def send_ending(outlet, broken)
        slot = outlet.slot
        gen = outlet.gen
        return @uv.kiln_uv_abort(slot, gen) if broken

        ending = outlet.ending
        @uv.kiln_uv_send(slot, gen, EMPTY_BODY, 0, ending, ending.bytesize, outlet.keep ? 0 : 1)
      end

    end
  end
end
