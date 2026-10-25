module Kiln
  module Routing
    class Router
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

    end
  end
end
