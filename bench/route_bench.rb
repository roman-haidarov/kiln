require "kiln"

class BenchHandler
  def call(ctx) = ctx.res.status
end

handler = BenchHandler.new
router = Kiln::Router.new
16.times do |i|
  router.get("/svc#{i}/items/:id", handler)
  router.post("/svc#{i}/items", handler)
end
req = Kiln::Request.new("GET", "/svc15/items/42", {}, nil)
n = (ARGV[0] || "2000000").to_i
t = Kiln.now
n.times do
  router.call(Kiln::Context.new(req, Kiln::Response.new, nil, "r", 0.0))
end
puts "routes=#{n} seconds=#{(Kiln.now - t).round(3)}"
