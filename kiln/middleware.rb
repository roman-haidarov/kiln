module Kiln
  module Quiet
    private

    def safe_log
      yield
    rescue Exception
      nil
    end
  end

  class RequestId
    def initialize(nxt) = @next = nxt

    def call(ctx)
      current = Thread.current
      request_id = Kiln.request_text(ctx.id)
      current[:request_id] = request_id
      ctx.res.headers['X-Request-Id'] = request_id
      @next.call(ctx)
    ensure
      current[:request_id] = nil
    end
  end

  class AccessLog
    include Quiet

    def initialize(nxt, log)
      @next = nxt
      @log = log
    end

    def call(ctx)
      started = Kiln.now
      begin
        @next.call(ctx)
      ensure
        safe_log do
          req = ctx.req
          @log.info("#{req.verb} #{req.path} -> #{ctx.res.status} #{((Kiln.now - started) * 1000).round(1)}ms")
        end
      end
    end
  end

  class Rescue
    def initialize(nxt, log)
      @next = nxt
      @log = log
    end

    def call(ctx)
      @next.call(ctx)
    rescue ClientGone
      raise
    rescue Exception => err
      Kiln.dispatch_failure(@log, ctx, err)
    end
  end
end
