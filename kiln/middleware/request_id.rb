module Kiln
  module Middleware
    class RequestId
      def initialize(nxt) = @next = nxt

      def call(ctx)
        current = Thread.current
        request_id = Kiln::Observability.request_text(ctx.id)
        current[:request_id] = request_id
        ctx.res.headers['X-Request-Id'] = request_id
        @next.call(ctx)
      ensure
        current[:request_id] = nil
      end
    end
  end
end
