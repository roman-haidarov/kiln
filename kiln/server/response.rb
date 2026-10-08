module Kiln
  class Server
    private

    def serve(req, slot, deadline, id, box)
      begin
        Thread.current[:request_id] = id
        Thread.current[:kiln_deadline] = deadline
        Thread.current[:kiln_fd] = slot.sock.fileno
        ctx = Context.new(req, Response.new, @app, id, deadline)
        dispatch(ctx)
        go = @lock.synchronize do
          if slot.state == :reaping
            :reaped
          elsif Kiln.now > slot.deadline + @kill_grace
            unhandle(slot)
            slot.state = :reaping
            @late += 1
            :late
          else
            slot.state = :writing
            unhandle(slot)
            :write
          end
        end
        if go == :late
          if flush_outbox(slot.sock, box, Kiln.now + 0.5)
            write_all(slot.sock, TIMEOUT_RESPONSE, Kiln.now + 0.5)
          end
          return false
        end
        return false unless go == :write
        return false if ctx.gone
        write_response(slot.sock, req, ctx.res, box)
      ensure
        Thread.current[:request_id] = nil
        Thread.current[:kiln_deadline] = nil
        Thread.current[:kiln_fd] = nil
        @lock.synchronize do
          slot.state = :idle unless slot.state == :reaping
          unhandle(slot)
          if slot.flying
            slot.flying = false
            @in_flight -= 1
          end
        end
      end
    end

    def begin_handling(slot, deadline)
      id = @lock.synchronize do
        unless @shut || slot.done || slot.state == :reaping
          slot.flying = true
          slot.deadline = deadline
          slot.state = :handling
          heap_push(slot)
          if slot.hidx == 0 && deadline + @kill_grace < @reap_target && @reap_wake.empty?
            begin
              @reap_wake.push(true, true)
            rescue ThreadError
              nil
            end
          end
          @in_flight += 1
          @seq += 1
        end
      end
      id && id.to_s(36)
    end

    def write_response(sock, req, res, box)
      keep = HttpSyntax.persistent?(req.http_version, req.header("connection")) && !@draining
      body = Response.payload(res.status, res.body)
      wire = Response.build_head(res.status, res.headers, body.bytesize, keep, version: req.http_version)
      limit = Kiln.now + @write_timeout
      status = Response.valid_status?(res.status) ? res.status : 500
      bare = req.verb == "HEAD" || Response.no_body?(status) || body.empty?
      if bare || body.bytesize <= INLINE_BODY
        wire << (body.ascii_only? ? body : body.b) unless bare
        if keep && box.fits?(wire.bytesize)
          box.push(wire)
          return true
        end
        unless box.empty?
          return false unless flush_outbox(sock, box, limit)
          if keep && box.fits?(wire.bytesize)
            box.push(wire)
            return true
          end
        end
        sent = write_all(sock, wire, limit)
      else
        sent = flush_outbox(sock, box, limit) && write_all(sock, wire, limit) && write_all(sock, body, limit)
      end
      keep && sent
    end

    def dispatch(ctx)
      @handler.call(ctx)
    rescue ClientGone
      ctx.gone = true
    rescue DeadlineExceeded
      ctx.res.text("deadline exceeded\n", status: 504)
    rescue PoolTimeout
      ctx.res.text("busy\n", status: 503)
    rescue Exception => e
      raise if Kiln.unwind?(e)
      log_error(e)
      ctx.res.text("internal error\n", status: 500)
    end

    def log_error(error)
      frames = Array(error.backtrace).first(12).join(" ")
      @log.error("#{error.class}: #{error.message} #{frames}")
    rescue Exception
      nil
    end
  end
end
