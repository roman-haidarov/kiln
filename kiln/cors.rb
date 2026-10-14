module Kiln
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

  class Cors
    ANY = '*'.freeze
    NONE = [ANY].drop(1).freeze
    VARY_PREFLIGHT = 'Origin, Access-Control-Request-Method, Access-Control-Request-Headers'.freeze

    def initialize(nxt, origins:, methods: %w[GET HEAD POST PUT PATCH DELETE], headers: NONE, expose: NONE,
                   credentials: false, max_age: 600)
      @next = nxt
      raise ArgumentError, 'origins must be a non-empty list' unless origins.is_a?(Array) && !origins.empty?

      @any = origins.include?(ANY)
      raise ArgumentError, 'credentials cannot be combined with origin "*"' if @any && credentials

      @origins = lookup(origins)
      @methods = verbs(methods)
      @allow_methods = @methods.join(', ').freeze
      @headers = lookup(headers)
      @allow_headers = listing(headers)
      @expose = listing(expose)
      @credentials = credentials == true
      @max_age = Integer(max_age).to_s.freeze
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

    def lookup(names)
      out = {}
      index = 0
      while index < names.size
        out[names[index].to_s.downcase] = true
        index += 1
      end
      out
    end

    def listing(names)
      out = +''
      index = 0
      while index < names.size
        out << ', ' unless index.zero?
        out << names[index].to_s
        index += 1
      end
      out.freeze
    end

    def verbs(names)
      out = []
      index = 0
      while index < names.size
        verb = names[index].to_s.upcase
        out << verb unless out.include?(verb)
        index += 1
      end
      out.freeze
    end

    def allowed?(origin)
      return true if @any

      @origins.key?(origin.downcase)
    end

    def preflight(ctx, origin, wanted)
      res = ctx.res
      headers = res.headers
      headers['Vary'] = VARY_PREFLIGHT
      res.status = 204
      res.body = ''
      return unless allowed?(origin) && @methods.include?(wanted.upcase) && headers_allowed?(ctx.req)

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
