module Kiln
  module Routing
    class Router
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
          marks = ScopeMark.new(@scope.size, @wraps.size, @limits.size)
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
          @scope.slice!(marks.segments, @scope.size - marks.segments)
          @wraps.slice!(marks.wrappers, @wraps.size - marks.wrappers)
          @limits.slice!(marks.limits, @limits.size - marks.limits)
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

    end
  end
end
