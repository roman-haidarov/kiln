module Kiln
  module Routing
    class Router
      RESOURCE_ACTIONS = { index: true, show: true, create: true, update: true, destroy: true }.freeze
      RESOURCE_ROUTES = [
        ['GET', :index, false], ['GET', :show, true], ['POST', :create, false],
        ['PUT', :update, true], ['PATCH', :update, true], ['DELETE', :destroy, true]
      ].freeze
      TRAILING_SLASH = %i[strict redirect].freeze
      EXACT_ROOT = '/'.freeze
      DOT_SEGMENTS = %w[. ..].freeze
      PERMANENT = %w[GET HEAD].freeze
      PARAM_LEADS = %w[: *].freeze
      SLASH = '/'.freeze
      HEAD = 'HEAD'.freeze
      GET = 'GET'.freeze
      UNSET = 1 << 62

      Route = Struct.new(:verb, :names, :handler, :dynamic, :glob, :seq, :limit)
      NO_LIMIT = -1

      class Node
        attr_reader :static, :param, :glob, :routes, :first

        def initialize
          @static = {}
          @param = nil
          @glob = nil
          @routes = []
          @first = UNSET
        end

        def reach(seq)
          @first = seq if seq < @first
          self
        end

        def static_child(seg) = @static[seg] ||= Node.new

        def param_child
          @param = Node.new if @param.nil?
          @param
        end

        def glob_child
          @glob = Node.new if @glob.nil?
          @glob
        end

        def add(route)
          @routes << route
          self
        end
      end

      module Drawing
        def draw
          yield self
          self
        end

        def configure(routes)
          routes.configure(self)
          self
        end

        def namespace(prefix, wrap: nil, limit: nil, &) = scope(prefix, wrap:, limit:, &)

        def scope(prefix, wrap: nil, limit: nil)
          demand_open
          check_limit(limit)
          marks = [@scope.size, @wraps.size, @limits.size]
          push_scope(prefix, wrap, limit)
          yield self
          self
        ensure
          pop_scope(marks) if marks
        end

        def resources(path, handlers, only: nil)
          demand_open
          actions = resource_actions(handlers, only)
          RESOURCE_ROUTES.each do |verb, action, member|
            add(verb, member ? "#{path}/:id" : path, handlers[action], nil) if actions.include?(action)
          end
          self
        end

        def get(path, handler, limit: nil) = add('GET', path, handler, limit)
        def post(path, handler, limit: nil) = add('POST', path, handler, limit)
        def put(path, handler, limit: nil) = add('PUT', path, handler, limit)
        def patch(path, handler, limit: nil) = add('PATCH', path, handler, limit)
        def delete(path, handler, limit: nil) = add('DELETE', path, handler, limit)
        def options(path, handler, limit: nil) = add('OPTIONS', path, handler, limit)

        def not_found(handler)
          demand_open
          @not_found = handler
          self
        end

        def method_not_allowed(handler)
          demand_open
          @not_allowed = handler
          self
        end

        def seal!
          @exact.each_key { |path| @fast[path] = winners(path) }
          @sealed = true
          self
        end

        private

        def push_scope(prefix, wrap, limit)
          @scope.concat(HTTP::PathSyntax.compile(prefix))
          @wraps << wrap if wrap
          @limits << limit if limit
        end

        def pop_scope(marks)
          depth, wraps, limits = marks
          @scope.slice!(depth, @scope.size - depth)
          @wraps.slice!(wraps, @wraps.size - wraps)
          @limits.slice!(limits, @limits.size - limits)
        end

        def resource_actions(handlers, only)
          raise ArgumentError, 'resource handlers' unless resource_handlers?(handlers)

          actions = only || handlers.keys
          raise ArgumentError, 'resource actions' unless actions.is_a?(Array) && actions.all? { |a| handlers.key?(a) }

          actions
        end

        def resource_handlers?(handlers)
          handlers.is_a?(Hash) && handlers.keys.all? { |action| RESOURCE_ACTIONS.key?(action) }
        end

        def check_limit(limit)
          return if limit.nil? || (limit.is_a?(Integer) && limit >= 0)

          raise ArgumentError, 'limit must be a non-negative Integer'
        end

        def demand_open
          raise FrozenError, 'router is sealed' if @sealed
        end
      end

      module Building
        private

        def add(verb, path, handler, limit = nil)
          demand_open
          check_limit(limit)
          segments = @scope + HTTP::PathSyntax.compile(path)
          node, names, glob = insert(segments, @seq)
          refuse_duplicate(node, verb, path)
          node.add(build_route(verb, names, handler, glob, limit))
          @seq += 1
          index_route(verb, segments, names, glob)
          self
        end

        def build_route(verb, names, handler, glob, limit)
          limit = @limits.last if limit.nil? && !@limits.empty?
          Route.new(verb, names, wrap(handler), variable_route?(names, glob), glob, @seq,
                    limit.nil? ? NO_LIMIT : limit)
        end

        def refuse_duplicate(node, verb, path)
          raise ArgumentError, "duplicate route #{verb} #{path}" if node.routes.any? { |route| route.verb == verb }
        end

        def index_route(verb, segments, names, glob)
          remember(@verbs, verb)
          exact = exact_key(segments, names, glob)
          @exact[exact] = true if exact
        end

        def insert(segments, seq)
          node = @root.reach(seq)
          names = [GET].drop(1)
          last = segments.size - 1
          index = 0
          while index < segments.size
            node = descend(node, segments[index], index == last, names).reach(seq)
            index += 1
          end
          names << '' if segments.empty?
          [node, names, !segments.empty? && segments[last].start_with?('*')]
        end

        def descend(node, seg, last, names)
          lead = seg[0]
          return static_descend(node, seg, names) unless PARAM_LEADS.include?(lead)

          name = seg[1..]
          raise ArgumentError, "empty parameter name in #{seg}" if name.empty?

          names << name
          return node.param_child if lead == ':'
          raise ArgumentError, "*#{name} must be the last segment" unless last

          node.glob_child
        end

        def static_descend(node, seg, names)
          names << ''
          node.static_child(static_segment(seg))
        end

        def static_segment(seg)
          decoded = HTTP::PathSyntax.segments("/#{seg}")
          raise ArgumentError, "invalid path segment #{seg}" unless decoded.is_a?(Array) && decoded.size == 1

          decoded[0]
        end

        def variable_route?(names, glob) = glob || names.any? { |name| !name.empty? }

        def exact_key(segments, names, glob)
          return nil if variable_route?(names, glob)
          return EXACT_ROOT if segments.empty?
          return nil if segments.any? { |seg| seg.include?('%') }

          "/#{segments.join('/')}".freeze
        end

        def wrap(handler)
          index = @wraps.size - 1
          while index >= 0
            handler = @wraps[index].call(handler)
            index -= 1
          end
          handler
        end
      end

      module Matching
        private

        def match(segs, verb)
          route = find(@root, segs, 0, verb, nil)
          return route if route || verb != HEAD

          find(@root, segs, 0, GET, nil)
        end

        def find(node, segs, index, verb, best)
          return best if best && node.first > best.seq
          return earlier(pick(node.routes, verb), best) if index == segs.size

          best = find_children(node, segs, index, verb, best)
          glob = node.glob
          return best unless glob && tail_safe?(segs, index)

          earlier(pick(glob.routes, verb), best)
        end

        def find_children(node, segs, index, verb, best)
          child = node.static[segs[index]]
          best = find(child, segs, index + 1, verb, best) if child
          param = node.param
          param ? find(param, segs, index + 1, verb, best) : best
        end

        def earlier(route, best)
          return best if route.nil?
          return route if best.nil? || route.seq < best.seq

          best
        end

        def winners(path)
          out = {}
          segs = HTTP::PathSyntax.segments(path)
          return out unless segs.is_a?(Array)

          record_winners(out, segs)
          out
        end

        def record_winners(out, segs)
          verbs = @verbs
          index = 0
          while index < verbs.size
            record_winner(out, segs, verbs[index])
            index += 1
          end
          record_winner(out, segs, HEAD)
        end

        def record_winner(out, segs, verb)
          route = match(segs, verb)
          out[verb] = route if route && !route.dynamic
        end

        def collect(node, segs, index, allow)
          return remember_all(node.routes, allow) if index == segs.size

          child = node.static[segs[index]]
          collect(child, segs, index + 1, allow) if child
          param = node.param
          collect(param, segs, index + 1, allow) if param
          glob = node.glob
          remember_all(glob.routes, allow) if glob && tail_safe?(segs, index)
        end

        def pick(routes, verb)
          index = 0
          limit = routes.size
          while index < limit
            route = routes[index]
            return route if route.verb == verb

            index += 1
          end
          nil
        end

        def remember_all(routes, allow)
          index = 0
          while index < routes.size
            remember(allow, routes[index].verb)
            index += 1
          end
        end

        def tail_safe?(segs, index)
          while index < segs.size
            seg = segs[index]
            return false if DOT_SEGMENTS.include?(seg) || seg.include?(SLASH)

            index += 1
          end
          true
        end
      end

      module Dispatch
        private

        def fast_route(path, verb)
          known = @fast[path]
          known ? known[verb] : nil
        end

        def dispatch(ctx, path, verb)
          segs = HTTP::PathSyntax.segments(path)
          return ctx.res.text("bad request\n", status: 400) if segs == :bad
          return missing(ctx, path) unless segs

          route = match(segs, verb)
          return invoke(route, ctx, segs) if route

          unrouted(ctx, segs)
        end

        def unrouted(ctx, segs)
          allow = [GET].drop(1)
          collect(@root, segs, 0, allow)
          return reject_verb(ctx, allow) unless allow.empty?

          fallback(ctx)
        end

        def invoke(route, ctx, segs)
          ctx.req.params = params(route, segs) if route.dynamic
          enter(route, ctx)
        end

        def enter(route, ctx)
          limit = route.limit
          return route.handler.call(ctx) if limit == NO_LIMIT

          req = ctx.req
          return ctx.res.text("payload too large\n", status: 413) if (req.content_length || 0) > limit

          req.limit_body(limit)
          route.handler.call(ctx)
        end

        def params(route, segs)
          names = route.names
          out = {}
          last = names.size - 1
          index = 0
          while index < last
            name = names[index]
            out[name] = segs[index] unless name.empty?
            index += 1
          end
          tail(out, route, segs, last)
        end

        def tail(out, route, segs, last)
          name = route.names[last]
          if route.glob
            out[name] = segs[last, segs.size - last].join(SLASH)
          elsif !name.empty?
            out[name] = segs[last]
          end
          out
        end

        def missing(ctx, path)
          return fallback(ctx) unless @redirect_slash && slash_redirect?(path)

          stripped = path.byteslice(0, path.bytesize - 1)
          segs = HTTP::PathSyntax.segments(stripped)
          return fallback(ctx) unless segs.is_a?(Array) && match(segs, ctx.req.verb)

          redirect(ctx, stripped)
        end

        def redirect(ctx, target)
          req = ctx.req
          query = req.query
          res = ctx.res
          res.headers['Location'] = query.empty? ? target : "#{target}?#{query}"
          res.text("redirect\n", status: PERMANENT.include?(req.verb) ? 301 : 308)
        end

        def slash_redirect?(path)
          path.bytesize > 1 && path.end_with?(SLASH) && !path.include?('//') && !path.include?('\\')
        end

        def fallback(ctx)
          handler = @not_found
          return handler.call(ctx) if handler

          ctx.res.text("not found\n", status: 404)
        end

        def reject_verb(ctx, allow)
          allow_head(allow)
          res = ctx.res
          res.headers['Allow'] = allow.join(', ')
          handler = @not_allowed
          return handler.call(ctx) if handler

          res.text("method not allowed\n", status: 405)
        end

        def server_options(ctx)
          req = ctx.req
          res = ctx.res
          return res.text("bad request\n", status: 400) unless req.verb == 'OPTIONS'

          verbs = @verbs.dup
          allow_head(verbs)
          remember(verbs, 'OPTIONS')
          res.headers['Allow'] = verbs.join(', ')
          res.status = 204
          res.body = ''
        end

        def remember(verbs, verb)
          verbs << verb unless verbs.include?(verb)
        end

        def allow_head(verbs)
          verbs << 'HEAD' if verbs.include?('GET') && !verbs.include?('HEAD')
        end
      end

      include Drawing
      include Building
      include Matching
      include Dispatch

      def initialize(trailing_slash: :strict)
        unless TRAILING_SLASH.include?(trailing_slash)
          raise ArgumentError, 'trailing_slash must be :strict or :redirect'
        end

        @redirect_slash = trailing_slash == :redirect
        init_tree
        init_scope
        @sealed = false
        @not_found = nil
        @not_allowed = nil
      end

      def sealed? = @sealed == true

      def call(ctx)
        req = ctx.req
        path = req.path
        return server_options(ctx) if path == '*'

        verb = req.verb
        route = fast_route(path, verb)
        return enter(route, ctx) if route

        dispatch(ctx, path, verb)
      end

      private

      def init_tree
        @root = Node.new
        @exact = {}
        @fast = {}
        @seq = 0
        @verbs = [GET].drop(1)
      end

      def init_scope
        @scope = [GET].drop(1)
        @wraps = [->(nxt) { nxt }].drop(1)
        @limits = [NO_LIMIT].drop(1)
      end
    end
  end
end
