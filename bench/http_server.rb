require "kiln"

class Hello
  def call(ctx) = ctx.res.text("ok\n")
end

class Slow
  def call(ctx)
    ctx.sleep(1.5)
    ctx.res.text("slow\n")
  rescue Kiln::DeadlineExceeded
    ctx.res.text("late\n", status: 504)
  end
end

class Big
  BODY = ("b" * 1_000_000).freeze
  def call(ctx) = ctx.res.text(BODY)
end

log = Kiln::Log.new
router = Kiln::Router.new
router.get("/health", Hello.new)
router.get("/slow", Slow.new)
router.get("/big", Big.new)
router.seal!
handler = Kiln::RequestId.new(Kiln::AccessLog.new(Kiln::Rescue.new(router, log), log))
server = Kiln::Server.new(handler, nil, log: log, port: (ENV["PORT"] || "19091").to_i,
                          host: "127.0.0.1", request_timeout: 5.0, max_conns: 1000,
                          coop_budget: (ENV["COOP"] || "4").to_i)
server.start
puts "ready port=#{server.port}"
Kernel.sleep (ARGV[0] || "30").to_f
server.shutdown(grace: 1.0)
log.close
