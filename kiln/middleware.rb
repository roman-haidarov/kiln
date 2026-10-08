module Kiln
  class RequestId
    def initialize(nxt) = @next = nxt

    def call(ctx)
      Thread.current[:request_id] = ctx.id
      ctx.res.headers["X-Request-Id"] = ctx.id
      @next.call(ctx)
    ensure
      Thread.current[:request_id] = nil
    end
  end

  class AccessLog
    def initialize(nxt, log)
      @next, @log = nxt, log
    end

    def call(ctx)
      t = Kiln.now
      begin
        @next.call(ctx)
      ensure
        safe_log { @log.info("#{ctx.req.verb} #{ctx.req.path} -> #{ctx.res.status} #{((Kiln.now - t) * 1000).round(1)}ms") }
      end
    end

    private

    def safe_log
      yield
    rescue Exception
      nil
    end
  end

  class Rescue
    def initialize(nxt, log)
      @next, @log = nxt, log
    end

    def call(ctx)
      @next.call(ctx)
    rescue ClientGone
      raise
    rescue DeadlineExceeded
      ctx.res.text("deadline exceeded\n", status: 504)
    rescue PoolTimeout
      ctx.res.text("busy\n", status: 503)
    rescue Exception => e
      raise if Kiln.unwind?(e)
      safe_log do
        bt = Array(e.backtrace).first(12).join(" ")
        @log.error("#{e.class}: #{e.message} #{bt}")
      end
      ctx.res.text("internal error\n", status: 500)
    end

    private

    def safe_log
      yield
    rescue Exception
      nil
    end
  end
end
