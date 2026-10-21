module Kiln
  module Middleware
    module Quiet
      private

      def safe_log
        yield
      rescue *Kiln::Runtime::FAILURES
        nil
      end
    end

    class AccessLog
      include Quiet

      def initialize(nxt, log)
        @next = nxt
        @log = log
      end

      def call(ctx)
        started = Kiln::Runtime.now
        begin
          @next.call(ctx)
        ensure
          safe_log do
            req = ctx.req
            took = ((Kiln::Runtime.now - started) * 1000).round(1)
            @log.info("#{req.verb} #{req.path} -> #{ctx.res.status} #{took}ms")
          end
        end
      end
    end
  end
end
