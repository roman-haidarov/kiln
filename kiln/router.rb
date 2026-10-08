module Kiln
  class Router
    Route = Struct.new(:verb, :segments, :names, :handler, :dynamic)
    RESOURCE_ACTIONS = { index: true, show: true, create: true, update: true, destroy: true }.freeze
    RESOURCE_ROUTES = [
      ['GET', :index, false], ['GET', :show, true], ['POST', :create, false],
      ['PUT', :update, true], ['PATCH', :update, true], ['DELETE', :destroy, true]
    ].freeze

    EXACT_ROOT = '/'.freeze

    def initialize
      @prefix = {}
      @dynamic = []
      @exact = {}
      @exact_only = true
      @scope = []
      @sealed = false
    end

    def draw
      yield self
      self
    end

    def configure(routes)
      routes.configure(self)
      self
    end

    def namespace(prefix, &blk) = scope(prefix, &blk)

    def scope(prefix)
      demand_open
      depth = @scope.size
      @scope.concat(PathSyntax.compile(prefix))
      yield self
      self
    ensure
      @scope.slice!(depth, @scope.size - depth) if depth
    end

    def resources(path, handlers, only: nil)
      demand_open
      names = handlers.keys if handlers.is_a?(Hash)
      raise ArgumentError, 'resource handlers' unless names&.all? { |action| RESOURCE_ACTIONS.key?(action) }

      actions = only || names
      unless actions.is_a?(Array) && actions.all? { |action| handlers.key?(action) }
        raise ArgumentError, 'resource actions'
      end

      RESOURCE_ROUTES.each do |verb, action, member|
        next unless actions.include?(action)

        route_path = member ? "#{path}/:id" : path
        add(verb, route_path, handlers[action])
      end
      self
    end

    def put(path, handler) = add('PUT', path, handler)
    def patch(path, handler) = add('PATCH', path, handler)
    def delete(path, handler) = add('DELETE', path, handler)
    def options(path, handler) = add('OPTIONS', path, handler)

    def seal!
      @sealed = true
      self
    end

    def sealed? = @sealed == true
    def get(path, handler) = add('GET', path, handler)
    def post(path, handler) = add('POST', path, handler)

    def call(ctx)
      req = ctx.req
      res = ctx.res
      path = req.path
      return server_options(ctx) if path == '*'

      routes = nil
      routes = @exact[path] if @exact_only && !path.include?('%')
      if routes
        route, allow = match_exact(req.verb, routes)
        return invoke(route, ctx, nil) if route
        return reject_verb(ctx, allow) if allow
      end

      segs = PathSyntax.segments(path)
      if segs == :bad
        return res.text("bad request\n", status: 400)
      elsif segs
        route, allow = match_route(req.verb, segs)
        return invoke(route, ctx, segs) if route
        return reject_verb(ctx, allow) if allow
      end

      res.text("not found\n", status: 404)
    end

    private

    def match_exact(verb, routes)
      fallback = nil
      allow = nil
      index = 0
      limit = routes.size
      while index < limit
        route = routes[index]
        index += 1
        verb_name = route.verb
        return [route, nil] if verb_name == verb

        fallback ||= route if verb == 'HEAD' && verb_name == 'GET'
        allow ||= []
        remember(allow, verb_name)
      end
      fallback ? [fallback, nil] : [nil, allow]
    end

    def match_route(verb, segs)
      fallback = nil
      allow = nil
      candidates = @prefix[segs[0] || ''] || @dynamic
      index = 0
      limit = candidates.size
      while index < limit
        route = candidates[index]
        index += 1
        segments = route.segments
        verb_name = route.verb
        next unless segments.size == segs.size
        next unless PathSyntax.match?(segments, route.names, segs)
        return [route, nil] if verb_name == verb

        fallback ||= route if verb == 'HEAD' && verb_name == 'GET'
        allow ||= []
        remember(allow, verb_name)
      end
      [fallback, allow]
    end

    def invoke(route, ctx, segs)
      ctx.req.params = PathSyntax.params(route.names, segs) if route.dynamic
      route.handler.call(ctx)
    end

    def reject_verb(ctx, allow)
      allow_head(allow)
      res = ctx.res
      res.headers['Allow'] = allow.join(', ')
      res.text("method not allowed\n", status: 405)
    end

    def server_options(ctx)
      req = ctx.req
      res = ctx.res
      return res.text("bad request\n", status: 400) unless req.verb == 'OPTIONS'

      verbs = []
      record_verbs(verbs)
      allow_head(verbs)
      remember(verbs, 'OPTIONS')
      res.headers['Allow'] = verbs.join(', ')
      res.status = 204
      res.body = ''
    end

    def record_verbs(verbs)
      buckets = [@dynamic]
      @prefix.each_value { |bucket| buckets << bucket }
      index = 0
      while index < buckets.size
        routes = buckets[index]
        cursor = 0
        while cursor < routes.size
          remember(verbs, routes[cursor].verb)
          cursor += 1
        end
        index += 1
      end
    end

    def remember(verbs, verb)
      verbs << verb unless verbs.include?(verb)
    end

    def allow_head(verbs)
      verbs << 'HEAD' if verbs.include?('GET') && !verbs.include?('HEAD')
    end

    def demand_open
      raise FrozenError, 'router is sealed' if @sealed
    end

    def add(verb, path, handler)
      demand_open
      segments = @scope + PathSyntax.compile(path)
      names = PathSyntax.param_names(segments)
      dynamic = names.any? { |name| !name.empty? }
      route = Route.new(verb, segments, names, handler, dynamic)
      @exact_only = false if dynamic
      first = segments[0]
      if first&.start_with?(':')
        @dynamic << route
        @prefix.each_key { |key| @prefix[key] << route }
      else
        key = first || ''
        bucket = @prefix[key] ||= @dynamic.dup
        bucket << route
      end
      unless dynamic
        exact = exact_key(segments)
        (@exact[exact] ||= []) << route if exact
      end
      self
    end

    def exact_key(segments)
      index = 0
      limit = segments.size
      while index < limit
        return nil if segments[index].include?('%')

        index += 1
      end
      return EXACT_ROOT if limit.zero?

      "/#{segments.join('/')}".freeze
    end
  end
end
