module Kiln
  module Routing
    class Router
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

    end
  end
end
