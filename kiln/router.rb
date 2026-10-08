module Kiln
  class Router
    Route = Struct.new(:verb, :segments, :names, :handler, :dynamic)
    RESOURCE_ACTIONS = { index: true, show: true, create: true, update: true, destroy: true }.freeze
    RESOURCE_ROUTES = [
      ["GET", :index, false], ["GET", :show, true], ["POST", :create, false],
      ["PUT", :update, true], ["PATCH", :update, true], ["DELETE", :destroy, true]
    ].freeze

    def initialize
      @prefix = {}
      @dynamic = []
      @scope = []
      @sealed = false
    end

    def configure(routes)
      routes.configure(self)
      self
    end

    def namespace(prefix, &blk) = scope(prefix, &blk)

    def scope(prefix)
      raise FrozenError, "router is sealed" if @sealed
      depth = @scope.size
      @scope.concat(PathSyntax.compile(prefix))
      yield self
      self
    ensure
      @scope.slice!(depth, @scope.size - depth) if depth
    end

    def resources(path, handlers, only: nil)
      raise FrozenError, "router is sealed" if @sealed
      unless handlers.is_a?(Hash) && handlers.keys.all? { |action| RESOURCE_ACTIONS.key?(action) }
        raise ArgumentError, "resource handlers"
      end
      actions = only || handlers.keys
      unless actions.is_a?(Array) && actions.all? { |action| handlers.key?(action) }
        raise ArgumentError, "resource actions"
      end
      RESOURCE_ROUTES.each do |verb, action, member|
        next unless actions.include?(action)
        route_path = member ? path + "/:id" : path
        add(verb, route_path, handlers[action])
      end
      self
    end

    def seal!
      @sealed = true
      self
    end

    def sealed? = @sealed == true
    def get(path, handler = nil, &block) = add("GET", path, select_handler(handler, block))
    def post(path, handler = nil, &block) = add("POST", path, select_handler(handler, block))
    def put(path, handler = nil, &block) = add("PUT", path, select_handler(handler, block))
    def patch(path, handler = nil, &block) = add("PATCH", path, select_handler(handler, block))
    def delete(path, handler = nil, &block) = add("DELETE", path, select_handler(handler, block))
    def options(path, handler = nil, &block) = add("OPTIONS", path, select_handler(handler, block))

    def call(ctx)
      return server_options(ctx) if ctx.req.path == "*"
      segs = PathSyntax.segments(ctx.req.path)
      return ctx.res.text("bad request\n", status: 400) if segs == :bad
      return ctx.res.text("not found\n", status: 404) if segs.nil?
      verb = ctx.req.verb
      fallback = nil
      allow = nil
      candidates = @prefix[segs[0] || ""] || @dynamic
      i = 0
      limit = candidates.size
      while i < limit
        route = candidates[i]
        i += 1
        next unless route.segments.size == segs.size
        next unless PathSyntax.match?(route.segments, route.names, segs)
        if route.verb == verb
          ctx.req.params = PathSyntax.params(route.names, segs) if route.dynamic
          return route.handler.call(ctx)
        end
        fallback ||= route if verb == "HEAD" && route.verb == "GET"
        allow ||= []
        allow << route.verb unless allow.include?(route.verb)
      end
      if fallback
        ctx.req.params = PathSyntax.params(fallback.names, segs) if fallback.dynamic
        return fallback.handler.call(ctx)
      end
      if allow
        allow << "HEAD" if allow.include?("GET") && !allow.include?("HEAD")
        ctx.res.headers["Allow"] = allow.join(", ")
        return ctx.res.text("method not allowed\n", status: 405)
      end
      ctx.res.text("not found\n", status: 404)
    end

    private

    def select_handler(handler, block)
      raise ArgumentError, "provide a handler or block" if handler && block
      selected = handler || block
      raise ArgumentError, "handler must respond to call" unless selected && selected.respond_to?(:call)
      selected
    end

    def server_options(ctx)
      return ctx.res.text("bad request\n", status: 400) unless ctx.req.verb == "OPTIONS"
      verbs = []
      @dynamic.each { |route| verbs << route.verb unless verbs.include?(route.verb) }
      @prefix.each_value { |bucket| bucket.each { |route| verbs << route.verb unless verbs.include?(route.verb) } }
      verbs << "HEAD" if verbs.include?("GET") && !verbs.include?("HEAD")
      verbs << "OPTIONS" unless verbs.include?("OPTIONS")
      ctx.res.headers["Allow"] = verbs.join(", ")
      ctx.res.status = 204
      ctx.res.body = ""
    end

    def add(verb, path, handler)
      raise FrozenError, "router is sealed" if @sealed
      segments = @scope + PathSyntax.compile(path)
      names = PathSyntax.param_names(segments)
      route = Route.new(verb, segments, names, handler, names.any? { |name| !name.empty? })
      first = segments[0]
      if first && first.start_with?(":")
        @dynamic << route
        @prefix.keys.each { |key| @prefix[key] << route }
      else
        key = first || ""
        bucket = @prefix[key]
        unless bucket
          bucket = @dynamic.dup
          @prefix[key] = bucket
        end
        bucket << route
      end
      self
    end
  end
end
