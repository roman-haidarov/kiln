module Kiln
  # Middleware = объект с call(ctx), оборачивающий следующий.
  # Цепочка собирается явно при старте, как func(http.Handler) http.Handler в Go.
  class RequestId
    def initialize(nxt) = @next = nxt

    def call(ctx)
      Thread.current[:request_id] = ctx.id
      ctx.res.headers["X-Request-Id"] = ctx.id
      @next.call(ctx)
    end
  end

  class AccessLog
    def initialize(nxt, log)
      @next, @log = nxt, log
    end

    def call(ctx)
      t = Kiln.now
      @next.call(ctx)
      @log.info("#{ctx.req.verb} #{ctx.req.path} -> #{ctx.res.status} #{((Kiln.now - t) * 1000).round(1)}ms")
    end
  end

  # Ошибки -> 500/504. Здесь НЕ перебрасываем: в Spinel ensure в кадре,
  # где rescue делает raise, не выполняется.
  class Rescue
    def initialize(nxt, log)
      @next, @log = nxt, log
    end

    def call(ctx)
      @next.call(ctx)
    rescue DeadlineExceeded
      ctx.res.text("deadline exceeded\n", status: 504)
    rescue PoolTimeout
      ctx.res.text("busy\n", status: 503)
    rescue => e
      @log.error("#{e.class}: #{e.message}")
      ctx.res.text("internal error\n", status: 500)
    end
  end
end
