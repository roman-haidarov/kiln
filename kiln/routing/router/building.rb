module Kiln
  module Routing
    class Router
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

    end
  end
end
