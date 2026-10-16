module Kiln
  class Controller
    attr_reader :ctx

    def initialize(ctx) = @ctx = ctx

    def req = @ctx.req
    def res = @ctx.res
    def params = @ctx.req.params
  end
end
