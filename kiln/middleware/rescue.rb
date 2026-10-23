module Kiln
  module Middleware
    class Rescue
      def initialize(nxt, log)
        @next = nxt
        @log = log
      end

      def call(ctx)
        @next.call(ctx)
      rescue Runtime::ClientGone
        raise
      rescue *Kiln::Runtime::FAILURES => e
        Kiln::Runtime.dispatch_failure(@log, ctx, e)
      end
    end
  end
end
