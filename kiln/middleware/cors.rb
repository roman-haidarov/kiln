module Kiln
  module Middleware
    class Cors
      ANY = '*'.freeze
      NONE = [ANY].drop(1).freeze
      VARY_PREFLIGHT = 'Origin, Access-Control-Request-Method, Access-Control-Request-Headers'.freeze

      DEFAULT_METHODS = %w[GET HEAD POST PUT PATCH DELETE].freeze
      OPTION_KEYS = %i[methods headers expose credentials max_age].freeze

      def initialize(nxt, origins:, **options)
        @next = nxt
        check_options(origins, options)
        @any = origins.include?(ANY)
        @credentials = options.fetch(:credentials, false) == true
        @origins = lookup(origins)
        init_lists(options)
        @max_age = Integer(options.fetch(:max_age, 600)).to_s.freeze
      end

      def call(ctx)
        req = ctx.req
        origin = req.header('origin')
        return @next.call(ctx) if origin.nil?

        wanted = req.header('access-control-request-method')
        return preflight(ctx, origin, wanted) if req.verb == 'OPTIONS' && wanted

        begin
          @next.call(ctx)
        ensure
          actual(ctx.res.headers, origin, req.verb)
        end
      end

      private

      def check_options(origins, options)
        unknown = options.keys - OPTION_KEYS
        raise ArgumentError, "unknown cors option #{unknown.first}" unless unknown.empty?
        raise ArgumentError, 'origins must be a non-empty list' unless origins.is_a?(Array) && !origins.empty?
        return unless origins.include?(ANY) && options[:credentials]

        raise ArgumentError, 'credentials cannot be combined with origin "*"'
      end

      def init_lists(options)
        @methods = verbs(options.fetch(:methods) { DEFAULT_METHODS })
        @allow_methods = @methods.join(', ').freeze
        headers = options.fetch(:headers) { NONE }
        @headers = lookup(headers)
        @allow_headers = listing(headers)
        @expose = listing(options.fetch(:expose) { NONE })
      end

      def lookup(names) = names.to_h { |name| [name.to_s.downcase, true] }
      def listing(names) = names.join(', ').freeze
      def verbs(names) = names.map { |name| name.to_s.upcase }.uniq.freeze

      def allowed?(origin)
        return true if @any

        @origins.key?(origin.downcase)
      end

      def preflight(ctx, origin, wanted)
        res = ctx.res
        res.headers['Vary'] = VARY_PREFLIGHT
        res.status = 204
        res.body = ''
        return unless allowed?(origin) && @methods.include?(wanted.upcase) && headers_allowed?(ctx.req)

        grant_preflight(res.headers, origin)
      end

      def grant_preflight(headers, origin)
        stamp(headers, origin)
        headers['Access-Control-Allow-Methods'] = @allow_methods
        headers['Access-Control-Allow-Headers'] = @allow_headers unless @allow_headers.empty?
        headers['Access-Control-Max-Age'] = @max_age
      end

      def headers_allowed?(req)
        asked = req.header('access-control-request-headers')
        return true if asked.nil? || asked.strip.empty?

        asked.split(',').all? { |name| @headers.key?(name.strip.downcase) }
      end

      def actual(headers, origin, verb)
        headers.add('Vary', 'Origin')
        return unless allowed?(origin) && @methods.include?(verb)

        stamp(headers, origin)
        return if @expose.empty?

        headers.delete('Access-Control-Expose-Headers')
        headers.add('Access-Control-Expose-Headers', @expose)
      end

      def stamp(headers, origin)
        headers['Access-Control-Allow-Origin'] = @any ? ANY : origin
        headers['Access-Control-Allow-Credentials'] = 'true' if @credentials
      end
    end
  end
end
