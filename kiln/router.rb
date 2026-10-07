module Kiln
  class Router
    Route = Struct.new(:verb, :segments, :handler)

    def initialize
      @routes = []
    end

    def draw(&blk) = instance_eval(&blk)       # DSL выполняется один раз при старте
    def get(path, handler)  = add("GET", path, handler)
    def post(path, handler) = add("POST", path, handler)

    def call(ctx)
      segs = ctx.req.path.split("/").reject(&:empty?)
      @routes.each do |r|
        next unless r.verb == ctx.req.verb && r.segments.size == segs.size
        params = match(r.segments, segs)
        next unless params
        ctx.req.params = params
        return r.handler.call(ctx)
      end
      ctx.res.text("not found\n", status: 404)
    end

    private

    def add(verb, path, handler)
      @routes << Route.new(verb, path.split("/").reject(&:empty?), handler)
    end

    def match(pattern, segs)
      params = {}
      pattern.each_with_index do |s, i|
        if s.start_with?(":")
          params[s[1..]] = segs[i]
        elsif s != segs[i]
          return nil
        end
      end
      params
    end
  end
end
