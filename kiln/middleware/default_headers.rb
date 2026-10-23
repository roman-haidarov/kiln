module Kiln
  module Middleware
    class DefaultHeaders
      def initialize(nxt, headers)
        @next = nxt
        @pairs = headers.map { |name, value| [name.to_s.freeze, value.to_s.freeze].freeze }.freeze
      end

      def call(ctx)
        @next.call(ctx)
      ensure
        fill(ctx.res.headers)
      end

      private

      def fill(headers)
        index = 0
        while index < @pairs.size
          name, value = @pairs[index]
          headers[name] = value unless headers.key?(name)
          index += 1
        end
      end
    end
  end
end
