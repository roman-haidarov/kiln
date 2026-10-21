require 'kiln'

class BenchHandler
  def call(ctx) = ctx.res.status
end

handler = BenchHandler.new
router = Kiln::Routing::Router.new
16.times do |i|
  router.get("/svc#{i}/items/:id", handler)
  router.post("/svc#{i}/items", handler)
end
req = Kiln::HTTP::Request.new('GET', '/svc15/items/42', {}, nil)
n = (ARGV[0] || '2000000').to_i
t = Kiln::Runtime.now
n.times do
  router.call(Kiln::Routing::Context.new(req, Kiln::HTTP::Response.new, nil, 'r', 0.0))
end
puts "routes=#{n} seconds=#{(Kiln::Runtime.now - t).round(3)}"
