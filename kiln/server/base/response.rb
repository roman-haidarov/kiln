module Kiln
  class Server
    class Base
      private

      def serve(req, slot, deadline, id, box)
        current = Thread.current
        sock = slot.sock
        current[:request_id] = id
        current[:kiln_deadline] = deadline
        current[:kiln_fd] = sock.fileno
        ctx = Context.new(req, Response.new, @app, id, deadline)
        dispatch(ctx)
        shard = slot.shard
        go = @shard_locks[shard].synchronize do
          if slot.state == :reaping
            :reaped
          elsif Kiln.now > slot.deadline + @kill_grace
            unhandle(slot)
            slot.state = :reaping
            @late[shard] += 1
            :late
          else
            slot.state = :writing
            unhandle(slot)
            :write
          end
        end
        if go == :late
          late_deadline = Kiln.now + 0.5
          write_all(sock, TIMEOUT_RESPONSE, late_deadline) if flush_outbox(sock, box, late_deadline)
          return false
        end
        return false unless go == :write
        return false if ctx.gone

        write_response(sock, req, ctx.res, box)
      ensure
        current[:request_id] = nil
        current[:kiln_deadline] = nil
        current[:kiln_fd] = nil
        @shard_locks[slot.shard].synchronize do
          slot.state = :idle unless slot.state == :reaping
          unhandle(slot)
          if slot.flying
            slot.flying = false
            @in_flight[slot.shard] -= 1
          end
        end
      end

      def begin_handling(slot, deadline)
        shard = slot.shard
        @shard_locks[shard].synchronize do
          unless @shut_by_shard[shard] || slot.done || slot.state == :reaping
            slot.flying = true
            slot.deadline = deadline
            slot.state = :handling
            heap_push(slot)
            if slot.hidx.zero? && @reap_wake.empty?
              begin
                @reap_wake.push(true, true)
              rescue ThreadError
                nil
              end
            end
            @in_flight[shard] += 1
            @seq[shard] += @shard_count
          end
        end
      end

      def write_response(sock, req, res, box)
        version = req.http_version
        raw_status = res.status
        keep = HttpSyntax.persistent?(version, req.headers['connection']) && !@draining
        body = Response.payload(raw_status, res.body)
        head = Response.build_head(raw_status, res.headers, body.bytesize, keep, version: version)
        limit = Kiln.now + @write_timeout
        status = Response.valid_status?(raw_status) ? raw_status : 500
        body = EMPTY_BODY if req.verb == 'HEAD' || Response.no_body?(status)
        size = head.bytesize + body.bytesize
        return box.push(head, body) if keep && box.fits?(size)

        unless box.empty?
          return false unless flush_outbox(sock, box, limit)
          return box.push(head, body) if keep && box.fits?(size)
        end
        sent = write_all(sock, head, limit, body)
        keep && sent
      end

      def dispatch(ctx)
        @handler.call(ctx)
      rescue ClientGone
        ctx.gone = true
      rescue Exception => err
        Kiln.dispatch_failure(@log, ctx, err)
      end
    end
  end
end
