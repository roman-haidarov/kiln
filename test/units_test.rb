require "kiln"
require "stringio"

def check(label, ok)
  raise "FAIL #{label}" unless ok
  puts "ok   #{label}"
end

class Conn
  attr_reader :n
  def initialize(n) = @n = n
end

class AppError < StandardError; end
class FatalPoolError < Exception; end

puts "-- Pool"
made = Queue.new
closed = Queue.new
pool = Kiln::Pool.new(1, close: ->(c) { closed << c.n }) { made << 1; Conn.new(made.size) }
first = pool.with { |c| c.n }
begin
  pool.with { |c| raise AppError, "bad sql" }
rescue AppError
  nil
end
check "application error does not recreate resource", pool.with { |c| c.n } == first && made.size == 1
begin
  pool.with { |c| raise IOError, "broken pipe" }
rescue IOError
  nil
end
check "IO failure: resource replaced and old resource closed", pool.with { |c| c.n } == 2 && closed.size == 1
entered = Queue.new
t = Thread.new { pool.with { |c| entered << true; Kernel.sleep 5 } }
check "task acquired resource before kill", entered.pop(timeout: 1) == true
t.kill
t.join
check "kill inside with: resource replaced", pool.available == 1 && pool.with { |c| c.n } == 3
entered = Queue.new
holder = Thread.new { pool.with { |c| entered << true; Kernel.sleep 0.3 } }
check "pool holder acquired resource", entered.pop(timeout: 1) == true
r = begin
      pool.with(timeout: 0.05) { |c| :got }
    rescue Kiln::PoolTimeout
      :timeout
    end
holder.join
check "empty pool -> PoolTimeout", r == :timeout
check "with returns block value", pool.with { |c| 42 } == 42
bad_discard = Kiln::Pool.new(1, discard: ->(_e) { raise AppError, "discard failed" }) { Conn.new(1) }
r = begin
      bad_discard.with { raise IOError, "broken" }
    rescue IOError => e
      e.message
    end
check "discard failure preserves slot and original error", r == "broken" && bad_discard.available == 1
calls = Queue.new
lazy = Kiln::Pool.new(3) { calls << 1; Conn.new(calls.size) }
check "factory is not called when pool is created", calls.size == 0 && lazy.available == 3
lazy.with { |c| c.n }
lazy.with { |c| c.n }
check "resource is reused instead of recreated", calls.size == 1
failing = Kiln::Pool.new(1) { raise AppError, "db down" }
r = begin
      failing.with { |c| c }
    rescue AppError => e
      e.message
    end
check "factory error during checkout restores capacity", r == "db down" && failing.available == 1
r = begin
      Kiln::Pool.new(1) { nil }.with { |c| c }
    rescue ArgumentError => e
      e.message
    end
check "factory cannot return nil", r == "pool factory returned no resource"
validated_closed = Queue.new
validated = Kiln::Pool.new(1, close: ->(c) { validated_closed << c.n }, validate: ->(_c) {
  raise FatalPoolError, "validation interrupted"
}) { Conn.new(301) }
validated.with { |c| c.n }
r = begin
      validated.with { |c| c.n }
    rescue FatalPoolError
      :interrupted
    end
check "interrupt during validate closes checked-out resource and restores capacity", r == :interrupted && validated_closed.size == 1 && validated.available == 1
closing_calls = Queue.new
closing = Kiln::Pool.new(1, discard: ->(_e) { true }, close: ->(_c) { raise FatalPoolError, "close interrupted" }) {
  closing_calls << true
  Conn.new(closing_calls.size)
}
r = begin
      closing.with { raise IOError, "broken" }
    rescue FatalPoolError
      :interrupted
    end
check "interrupt during close keeps slot quarantined", r == :interrupted && closing.available == 0 && closing.quarantined == 1 && closing.close_failures == 1 && closing.consistent?
r = begin
      closing.with(timeout: 0.02) { |c| c.n }
    rescue Kiln::PoolTimeout
      :timeout
    end
check "no new resource is created after interrupted close", r == :timeout && closing_calls.size == 1
born = Queue.new
aged = Kiln::Pool.new(1, max_lifetime: 0.05, close: ->(c) { closed << c.n }) { born << 1; Conn.new(100 + born.size) }
first_aged = aged.with { |c| c.n }
Kernel.sleep 0.08
second_aged = aged.with { |c| c.n }
check "max_lifetime: expired resource is closed and replaced", first_aged == 101 && second_aged == 102
healthy = Queue.new
checked = Kiln::Pool.new(1, validate: ->(c) { c.n != 201 }) { healthy << 1; Conn.new(200 + healthy.size) }
checked.with { |c| c.n }
check "validate: rejected resource is replaced", checked.with { |c| c.n } == 202

puts "-- Response"
res = Kiln::Response.new
res.text("secret", status: 204)
wire = res.to_wire(true)
check "204 sends no body or Content-Length", wire.end_with?("\r\n\r\n") && !wire.include?("Content-Length") && !wire.include?("secret")
res.text("secret", status: 304)
wire = res.to_wire(true)
check "304 sends no body", wire.end_with?("\r\n\r\n") && !wire.include?("secret")
res.text("secret", status: 205)
wire = res.to_wire(true)
check "205 sends zero length and no body", wire.include?("Content-Length: 0\r\n") && wire.end_with?("\r\n\r\n")
res.status = 100
res.body = "secret"
res.headers["X-Leak"] = "secret"
wire = res.to_wire(true)
check "informational status cannot be sent as final response", wire.start_with?("HTTP/1.1 500 ") && wire.end_with?("internal error\n") && !wire.include?("X-Leak") && !wire.include?("secret")
headers = Kiln::Headers.new
headers["Content-Type"] = "text/plain"
headers["X-Bad"] = "a\r\nb"
payload = "hello"
wire = Kiln::Response.build_wire(200, headers, payload, false)
check "response formatting does not modify input", headers["Content-Type"] == "text/plain" && payload == "hello"
check "unsafe header is rejected on insertion", wire.include?("Content-Type: text/plain\r\n") && !wire.include?("X-Bad:") && !headers.key?("X-Bad")
dated = Kiln::Headers.new
dated["DATE"] = "custom"
wire = Kiln::Response.build_wire(200, dated, "ok", false)
check "Date header is recognized case-insensitively", wire.scan(/(?:\A|\r\n)Date:/i).size == 1 && wire.include?("DATE: custom\r\n")

r = begin
      Kiln::Server.new(nil, nil, log: nil, port: 0, coop_budget: -1)
      :accepted
    rescue ArgumentError
      :rejected
    end
check "coop_budget rejects negative values", r == :rejected

puts "-- HTTP syntax"
head = "GET /items/42 HTTP/1.1\r\nHost: example.org\r\nAccept: text/plain\r\nAccept: application/json".b
parsed = Kiln::HttpSyntax.parse_head(head)
check "header parsing does not modify input string", head.include?("Accept: text/plain\r\nAccept: application/json")
check "repeated headers are combined", parsed[0] == "1.1" && parsed[1] == "GET" && parsed[2] == "/items/42" && parsed[3]["accept"] == "text/plain, application/json"
check "duplicate Host is rejected", Kiln::HttpSyntax.parse_head("GET / HTTP/1.1\r\nHost: a\r\nHost: b".b) == :bad
check "body length limit works independently of server", Kiln::HttpSyntax.content_length({"content-length" => "12"}, 10) == :too_long
target, authority = Kiln::HttpSyntax.absolute_target("https://example.org/items/42")
check "absolute-form extracts path and authority", target == "/items/42" && authority == "example.org"
check "keep-alive honors version and Connection", Kiln::HttpSyntax.persistent?("1.0", "keep-alive") && !Kiln::HttpSyntax.persistent?("1.1", "close")

puts "-- Router"
block_router = Kiln::Router.new
  .get("/block") { |c| c.text("block route") }
  .post("/block", ->(c) { c.json("{}", status: 201) })
  .get("/created") { |c| c.status(202); c.header("X-Result", "ready"); c.text("accepted") }
req = Kiln::Request.new("GET", "/block", {}, nil)
res = Kiln::Response.new
block_router.call(Kiln::Context.new(req, res, nil, "block", 0.0))
check "route blocks receive the router context", res.body == "block route" && res.headers["content-type"] == "text/plain"
req = Kiln::Request.new("POST", "/block", {}, nil)
res = Kiln::Response.new
block_router.call(Kiln::Context.new(req, res, nil, "block", 0.0))
check "context JSON helper delegates response status and content type", res.body == "{}" && res.status == 201 && res.headers["content-type"] == "application/json"
req = Kiln::Request.new("GET", "/created", {}, nil)
res = Kiln::Response.new
block_router.call(Kiln::Context.new(req, res, nil, "block", 0.0))
check "context status and header helpers", res.body == "accepted" && res.status == 202 && res.headers["x-result"] == "ready"
handler_error = begin
  Kiln::Router.new.get("/bad")
  :accepted
rescue ArgumentError
  :rejected
end
check "route registration requires a handler", handler_error == :rejected

module RouterUserRoutes
  class << self
    def configure(router)
      router.scope("/api") do |api|
        api.get("/users/:id", ->(c) { c.res.text("user=#{c.req.params['id']}") })
      end
    end
  end
end

module RouterBookController
  class << self
    def configure(router)
      router.resources("/books", {
        index: method(:index), show: method(:show), create: method(:create),
        update: method(:update), destroy: method(:destroy)
      })
    end

    def index(ctx) = ctx.res.text("index")
    def show(ctx) = ctx.res.text("show=#{ctx.req.params['id']}")
    def create(ctx) = ctx.res.text("create")
    def update(ctx) = ctx.res.text("update=#{ctx.req.params['id']}")
    def destroy(ctx) = ctx.res.text("destroy=#{ctx.req.params['id']}")
  end
end

router = Kiln::Router.new
router.get("/items/:id", ->(c) { c.res.text("get=#{c.req.params['id']}") })
router.post("/items/:id", ->(c) { c.res.text("post=#{c.req.params['id']}") })
req = Kiln::Request.new("GET", "/items/42", {}, nil)
res = Kiln::Response.new
router.call(Kiln::Context.new(req, res, nil, "route", 0.0))
check "GET selects its route and parameters", res.body == "get=42" && req.params["id"] == "42"
req = Kiln::Request.new("POST", "/items/43", {}, nil)
res = Kiln::Response.new
router.call(Kiln::Context.new(req, res, nil, "route", 0.0))
check "POST selects its route", res.body == "post=43"
req = Kiln::Request.new("HEAD", "/items/44", {}, nil)
res = Kiln::Response.new
router.call(Kiln::Context.new(req, res, nil, "route", 0.0))
check "HEAD uses GET", res.body == "get=44"
req = Kiln::Request.new("DELETE", "/items/45", {}, nil)
res = Kiln::Response.new
router.call(Kiln::Context.new(req, res, nil, "route", 0.0))
check "405 lists methods without duplicates", res.status == 405 && res.headers["Allow"] == "GET, POST, HEAD"
req = Kiln::Request.new("GET", "/unknown", {}, nil)
res = Kiln::Response.new
router.call(Kiln::Context.new(req, res, nil, "route", 0.0))
check "unknown path returns 404", res.status == 404
root_router = Kiln::Router.new
root_router.get("/", ->(c) { c.res.text("root") })
req = Kiln::Request.new("GET", "/", {}, nil)
res = Kiln::Response.new
root_router.call(Kiln::Context.new(req, res, nil, "route", 0.0))
check "root route is found through index", res.body == "root"
ordered_router = Kiln::Router.new
ordered_router.get("/:section/items", ->(c) { c.res.text("dynamic=#{c.req.params['section']}") })
ordered_router.get("/shop/items", ->(c) { c.res.text("static") })
req = Kiln::Request.new("GET", "/shop/items", {}, nil)
res = Kiln::Response.new
ordered_router.call(Kiln::Context.new(req, res, nil, "route", 0.0))
check "dynamic first segment preserves order", res.body == "dynamic=shop"
reverse_router = Kiln::Router.new
reverse_router.get("/shop/items", ->(c) { c.res.text("static") })
reverse_router.get("/:section/items", ->(c) { c.res.text("dynamic=#{c.req.params['section']}") })
req = Kiln::Request.new("GET", "/shop/items", {}, nil)
res = Kiln::Response.new
reverse_router.call(Kiln::Context.new(req, res, nil, "route", 0.0))
check "static route also preserves order", res.body == "static"
req = Kiln::Request.new("GET", "/other/items", {}, nil)
res = Kiln::Response.new
reverse_router.call(Kiln::Context.new(req, res, nil, "route", 0.0))
check "dynamic route works with a new prefix", res.body == "dynamic=other"
req = Kiln::Request.new("GET", "/items/plain".b, {}, nil)
res = Kiln::Response.new
router.call(Kiln::Context.new(req, res, nil, "route", 0.0))
check "plain byte path is normalized to UTF-8", req.params["id"] == "plain" && req.params["id"].encoding == Encoding::UTF_8
req = Kiln::Request.new("GET", "/items/a%20b", {}, nil)
res = Kiln::Response.new
router.call(Kiln::Context.new(req, res, nil, "route", 0.0))
check "percent-encoded segment is decoded", req.params["id"] == "a b"
req = Kiln::Request.new("GET", "/items/a%GG", {}, nil)
res = Kiln::Response.new
router.call(Kiln::Context.new(req, res, nil, "route", 0.0))
check "invalid percent escape is rejected", res.status == 400
configured = Kiln::Router.new
  .scope("/api") do |api|
    api.scope("/v1") { |v1| v1.get("/health", ->(c) { c.res.text("ok") }) }
  end
  .configure(RouterUserRoutes)
check "router chains and module scopes compose", configured.get("/unused", ->(c) { c }) == configured
req = Kiln::Request.new("GET", "/api/v1/health", {}, nil)
res = Kiln::Response.new
configured.call(Kiln::Context.new(req, res, nil, "route", 0.0))
check "nested scope prefixes routes", res.body == "ok"
req = Kiln::Request.new("GET", "/api/users/42", {}, nil)
res = Kiln::Response.new
configured.call(Kiln::Context.new(req, res, nil, "route", 0.0))
check "configure mounts module routes", res.body == "user=42" && req.params["id"] == "42"
direct_res = Kiln::Response.new
RouterBookController.index(Kiln::Context.new(nil, direct_res, nil, "resource", 0.0))
check "resource controller procedure accepts context", direct_res.body == "index"
resource_router = Kiln::Router.new.namespace("/api") do |api|
  api.configure(RouterBookController)
end
[
  ["GET", "/api/books", "index"],
  ["GET", "/api/books/7", "show=7"],
  ["POST", "/api/books", "create"],
  ["PUT", "/api/books/7", "update=7"],
  ["PATCH", "/api/books/7", "update=7"],
  ["DELETE", "/api/books/7", "destroy=7"]
].each do |verb, path, expected|
  req = Kiln::Request.new(verb, path, {}, nil)
  res = Kiln::Response.new
  resource_router.call(Kiln::Context.new(req, res, nil, "resource", 0.0))
  check "resources maps #{verb} #{path}", res.body == expected
end
limited_resources = Kiln::Router.new.resources("/books", {
  show: RouterBookController.method(:show), create: RouterBookController.method(:create)
}, only: [:show])
req = Kiln::Request.new("POST", "/books", {}, nil)
res = Kiln::Response.new
limited_resources.call(Kiln::Context.new(req, res, nil, "resource", 0.0))
check "resources only registers selected actions", res.status == 404

puts "-- Context"
ctx = Kiln::Context.new(nil, nil, nil, "t1", Kiln.now + 0.5)
check "all: result order preserved; nil and false are valid", ctx.all([-> { Kernel.sleep 0.02; 1 }, -> { nil }, -> { false }]) == [1, nil, false]
r = begin
      ctx.all([-> { Kernel.sleep 2; 1 }, -> { raise AppError, "db down" }])
    rescue AppError => e
      e.message
    end
check "all: sibling error propagates immediately, not at deadline", r == "db down"
check "first: false is a successful result", ctx.first([-> { false }, -> { Kernel.sleep 2; true }]) == false
r = begin
      ctx.first([-> { raise AppError, "a" }, -> { raise AppError, "b" }])
    rescue AppError
      :error
    end
check "first: all tasks failed -> task error", r == :error
r = begin
      ctx.first([])
    rescue ArgumentError
      :arg
    end
check "first: empty list -> ArgumentError", r == :arg
seen = Queue.new
ctx.all([-> { seen << Thread.current[:request_id]; seen << (Kiln.deadline > 0) }])
check "subtask inherits request id and deadline", seen.pop == "t1" && seen.pop == true
late = Kiln::Context.new(nil, nil, nil, "t2", Kiln.now - 1)
r = begin
      late.all([-> { 1 }])
    rescue Kiln::DeadlineExceeded
      :deadline
    end
check "all does not start tasks after deadline", r == :deadline
standalone = Kiln::Context.new(nil, nil, nil, "sleep", Kiln.now + 0.03)
t = Kiln.now
r = begin
      standalone.sleep(1)
    rescue Kiln::DeadlineExceeded
      :deadline
    end
check "ctx.sleep observes deadline without thread-local state", r == :deadline && Kiln.now - t < 0.2

puts "-- CpuPool"
cpu = Kiln::CpuPool.new(1, queue: 1)
Thread.current[:request_id] = "cpu-request"
rid = cpu.run { Thread.current[:request_id] }
Thread.current[:request_id] = nil
check "CPU task inherits request id", rid == "cpu-request" && cpu.run { Thread.current[:request_id] }.nil?
started = Queue.new
busy = Thread.new { cpu.run(timeout: 2) { started << 1; Kernel.sleep 0.4 } }
check "CPU worker started task", started.pop(timeout: 1) == 1
queued = Thread.new { cpu.run(timeout: 2) { 42 } }
limit = Kiln.now + 1
Kernel.sleep 0.005 while cpu.queued == 0 && Kiln.now < limit
check "CPU queue is full", cpu.queued == 1
Thread.current[:kiln_deadline] = Kiln.now + 0.05
r = begin
      cpu.run(timeout: 1) { 99 }
    rescue Kiln::DeadlineExceeded
      :deadline
    end
Thread.current[:kiln_deadline] = nil
busy.join
queued.join
check "full CPU queue at deadline -> DeadlineExceeded", r == :deadline && cpu.skipped == 0

puts "-- Supervisor"
io = StringIO.new
log = Kiln::Log.new(io)
runs = Queue.new
sup = Kiln::Supervisor.new(log)
sup.child("flaky") do
  runs << 1
  raise AppError, "boom #{runs.size}" if runs.size < 3
  Kernel.sleep 5
end
Kernel.sleep 0.5
check "service retries until startup succeeds", runs.size == 3 && sup.restarts == 2
sup.stop
check "stop does not raise", true

puts "-- Log"
log.info("line1\nERROR forged")
log.close
check "newline cannot forge a log entry", io.string.lines.size == 3 && io.string.include?("line1 ERROR forged")
check "no log entries were dropped", log.dropped == 0

puts "-- Spinel guards"
class BrokenLog
  def info(msg) = raise(IOError, "stdout closed")
  def error(msg) = raise(IOError, "stdout closed")
end
class OkHandler
  def call(ctx) = ctx.res.text("fine", status: 201)
end
class FailHandler
  def call(ctx) = raise(ArgumentError, "boom")
end
guard_req = Kiln::Request.new("GET", "/", {}, nil)
guard_ctx = Kiln::Context.new(guard_req, Kiln::Response.new, nil, "g", 0.0)
r = begin
      Kiln::AccessLog.new(OkHandler.new, BrokenLog.new).call(guard_ctx)
      guard_ctx.res.status
    rescue Exception => e
      e.class.name
    end
check "AccessLog: logging failure does not erase completed response", r == 201
outer = Queue.new
guard_ctx = Kiln::Context.new(guard_req, Kiln::Response.new, nil, "g", 0.0)
def guarded(mw, ctx, mark)
  mw.call(ctx)
ensure
  mark << :ensure
end
r = begin
      guarded(Kiln::Rescue.new(FailHandler.new, BrokenLog.new), guard_ctx, outer)
      guard_ctx.res.status
    rescue Exception => e
      e.class.name
    end
check "Rescue: error -> 500 without re-raise; outer ensure ran", r == 500 && outer.size == 1
made = Queue.new
gp = Kiln::Pool.new(1) { made << 1; Conn.new(made.size) }
r = begin
      gp.with { |c| raise AppError, "sql" }
    rescue AppError => e
      e.message
    end
check "Pool#with: block error reaches caller and resource returns to pool", r == "sql" && gp.available == 1
check "Kiln.pause returns without recursing into Kernel.sleep", Kiln.pause(0.001).is_a?(Integer)

puts "-- Visibility and purity"
r = begin
      Kiln::HttpSyntax.encode_owned(+"x")
      :public
    rescue NoMethodError
      :private
    end
check "HttpSyntax: helper functions are private", r == :private
r = begin
      Kiln::PathSyntax.decode(+"x")
      :public
    rescue NoMethodError
      :private
    end
check "PathSyntax.decode is private", r == :private
cookies = Kiln::Headers.new
cookies.add("Set-Cookie", "a=1")
cookies.add("Set-Cookie", "b=2")
cookies["content-type"] = "text/plain"
cookies["Content-Type"] = "application/json"
cookies["Content-Length"] = "99"
cookies["Bad Name"] = "x"
wire = Kiln::Response.build_wire(200, cookies, "{}", true)
check "Set-Cookie: both values are sent", wire.include?("Set-Cookie: a=1\r\n") && wire.include?("Set-Cookie: b=2\r\n")
check "[]= replaces values case-insensitively", wire.scan("Content-Type:").size == 1 && wire.include?("Content-Type: application/json\r\n")
check "managed and invalid headers are rejected", !wire.include?("99") && !wire.include?("Bad Name") && cookies.size == 3
path = "/a/%D0%BF/b".b
copy = path.dup
segs = Kiln::PathSyntax.segments(path)
check "PathSyntax.segments does not modify input", path == copy && path.encoding == Encoding::ASCII_8BIT
check "PathSyntax.segments decodes UTF-8", segs == ["a", "п", "b"] && segs[1].encoding == Encoding::UTF_8
names = Kiln::PathSyntax.param_names(Kiln::PathSyntax.compile("/u/:id/x/:tab"))
check "parameter names are computed at registration", names == ["", "id", "", "tab"]
check "PathSyntax.params", Kiln::PathSyntax.params(names, ["u", "7", "x", "info"]) == { "id" => "7", "tab" => "info" }

puts "-- HttpNative compared with reference HttpSyntax"
browser_head = "GET /products/42?ref=home HTTP/1.1\r\nHost: shop.example.com\r\nConnection: keep-alive\r\nsec-ch-ua: \"Chromium\";v=\"128\", \"Not;A=Brand\";v=\"24\"\r\nsec-ch-ua-mobile: ?0\r\nsec-ch-ua-platform: \"macOS\"\r\nUpgrade-Insecure-Requests: 1\r\nUser-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36\r\nAccept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8\r\nSec-Fetch-Site: same-origin\r\nSec-Fetch-Mode: navigate\r\nSec-Fetch-User: ?1\r\nSec-Fetch-Dest: document\r\nReferer: https://shop.example.com/\r\nAccept-Encoding: gzip, deflate, br, zstd\r\nAccept-Language: ru-RU,ru;q=0.9,en-US;q=0.8,en;q=0.7\r\nCookie: session=abc123def456; theme=dark; cart=9f8e7d6c".b
native_out = Kiln::HttpNative.scratch
check "browser request uses C fast path", Kiln::HttpNative.kiln_http_scan(browser_head, browser_head.bytesize, native_out, Kiln::HttpNative::CAP) == 16
crafted = [
  "GET /health HTTP/1.1\r\nHost: x", "GET / HTTP/1.0", "POST /a?b=1 HTTP/1.1\r\nHost: x\r\nContent-Length: 5",
  "GET /a HTTP/1.1\r\nHost: x\r\nX-A: 1\r\nX-A: 2", "GET /a HTTP/1.1\r\nHost: x\r\nHost: y",
  "GET /a HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 1", "\r\nGET /a HTTP/1.1\r\nHost: x",
  "GET  /a HTTP/1.1\r\nHost: x", "GET /a  HTTP/1.1\r\nHost: x", "GET /a HTTP/1.1 \r\nHost: x",
  "GET /a HTTP/1.2\r\nHost: x", "GET /a HTTP/2.0\r\nHost: x", "get /a HTTP/1.1\r\nHost: x",
  "GET /a HTTP/1.1\nHost: x", "GET /a HTTP/1.1\r\nHost: x\nX: y", "GET /a HTTP/1.1\r\nHost: x\r",
  "GET /a HTTP/1.1\r\n Host: x", "GET /a HTTP/1.1\r\nHost: x\r\n folded", "GET /a HTTP/1.1\r\nHost x",
  "GET /a HTTP/1.1\r\nHost : x", "GET /a HTTP/1.1\r\nBad Name: v", "GET /a HTTP/1.1\r\n: v",
  "GET /a HTTP/1.1\r\nX: a\tb", "GET /a HTTP/1.1\r\nX: \t a \t", "GET /a HTTP/1.1\r\nX:", "GET /a HTTP/1.1\r\nX:   ",
  "GET /a HTTP/1.1\r\nX: a\x01b", "GET /a\x7f HTTP/1.1\r\nHost: x", "GET /a\x00 HTTP/1.1\r\nHost: x",
  "GET /a HTTP/1.1\r\nX: \xD0\xBF\xD1\x80\xD0\xB8", "GET /a HTTP/1.1\r\nX: \xff\xfe", "GET /\xD0\xBF HTTP/1.1\r\nHost: x",
  "GET /a HTTP/1.1\r\nHost: x\r\n\r\nX: y", "GET /a HTTP/1.1\r\nHost: x\r\n", "", "GET", "GET /a"
]
many = (+"GET / HTTP/1.1\r\nHost: x").b
100.times { |i| many << "\r\nX-#{i}: v".b }
crafted << many
crafted << many + "\r\nX-extra: v".b
crafted << many + "\r\nX-extra v".b
crafted << browser_head
mismatch = crafted.count { |c| Kiln::HttpSyntax.parse_head(c.b) != Kiln::HttpNative.parse_head(c.b, native_out) }
check "constructed cases match reference (#{crafted.size})", mismatch == 0
pieces = [" ", "\t", "\r", "\n", ":", "\x00", "\x7f", "\xff", "A", "a", "/", "-", "\r\n", "\r\n ", "\r\nX-D: 1", "\r\nHost: z", "%"].map(&:b)
bases = [browser_head, "GET /health HTTP/1.1\r\nHost: 127.0.0.1:9000".b, "POST /x HTTP/1.0\r\nContent-Length: 3\r\nX-A: 1\r\nX-A: 2".b]
seed = 12_345
fuzz_total = 0
fuzz_mismatch = 0
fuzz_fast = 0
4000.times do |k|
  seed = (seed * 1_103_515_245 + 12_345) % 2_147_483_648
  text = bases[seed % bases.size].dup
  edits = 1 + (seed >> 8) % 3
  edits.times do
    seed = (seed * 1_103_515_245 + 12_345) % 2_147_483_648
    pos = (seed >> 4) % (text.bytesize + 1)
    piece = pieces[(seed >> 16) % pieces.size]
    case (seed >> 24) % 3
    when 0 then text = text.byteslice(0, pos) + piece + text.byteslice(pos, text.bytesize - pos).to_s
    when 1 then text = text.byteslice(0, pos) + piece + text.byteslice(pos + 1, text.bytesize).to_s
    else text = text.byteslice(0, pos) + text.byteslice(pos + 1, text.bytesize).to_s
    end
  end
  fuzz_total += 1
  fuzz_fast += 1 if Kiln::HttpNative.kiln_http_scan(text, text.bytesize, native_out, Kiln::HttpNative::CAP) >= 0
  fuzz_mismatch += 1 if Kiln::HttpSyntax.parse_head(text) != Kiln::HttpNative.parse_head(text, native_out)
end
check "mutation fuzzing: #{fuzz_total} cases; no mismatches", fuzz_mismatch == 0
check "some mutations use fast path (#{fuzz_fast > 0})", fuzz_fast > 0

puts "-- Pool: kill during checkout"
stress = Kiln::Pool.new(2) { Conn.new(1) }
victims = []
300.times do |k|
  victims << Thread.new { stress.with(timeout: 1) { |c| Kernel.sleep 0.001 * (k % 3) } }
  victims[k - 3].kill if k >= 3 && k % 2 == 0
end
victims.each { |th| th.join(2) }
check "resources remain after 300 killed threads", stress.available == 2 && stress.with { |c| c.n } == 1

puts "-- Router: seal and parameters"
sealed = Kiln::Router.new
sealed.get("/static", ->(c) { c.res.text("s") })
sealed.delete("/static", ->(c) { c.res.text("d") })
sealed.seal!
r = begin
      sealed.get("/late", ->(c) { c })
      :added
    rescue FrozenError
      :frozen
    end
check "routes cannot be added after seal!", r == :frozen && sealed.sealed?
sreq = Kiln::Request.new("DELETE", "/static", {}, nil)
sres = Kiln::Response.new
sealed.call(Kiln::Context.new(sreq, sres, nil, "s", 0.0))
check "DELETE route and shared empty params", sres.body == "d" && sreq.params.frozen? && sreq.params.empty?

puts "-- Pool: boundary cases"
r = begin
      Kiln::Pool.new(1, max_lifetime: -10) { Conn.new(1) }
      :accepted
    rescue ArgumentError
      :rejected
    end
check "negative max_lifetime is rejected", r == :rejected
narrow = Kiln::Pool.new(1) { Conn.new(7) }
held = Queue.new
release = Queue.new
holder = Thread.new { narrow.with { |c| held << true; release.pop } }
held.pop
waiter = Thread.new { narrow.with(timeout: 5) { |c| c.n } }
Kernel.sleep 0.05
check "second thread waits for resource", waiter.alive? && narrow.available == 0
waiter.kill
waiter.join(1)
release << true
holder.join
check "kill while waiting for resource does not lose capacity", narrow.available == 1 && narrow.with { |c| c.n } == 7

puts "-- HttpNative: scan_at boundaries"
data = "GET / HTTP/1.1\r\nHost: x\r\n\r\n".b
scratch = Kiln::HttpNative.scratch
check "scan_at within data bounds", Kiln::HttpNative.kiln_http_scan_at(data, data.bytesize, 0, data.bytesize - 4, scratch, Kiln::HttpNative::CAP) == 1
check "scan_at outside data bounds -> reject", Kiln::HttpNative.kiln_http_scan_at(data, data.bytesize, 10, data.bytesize, scratch, Kiln::HttpNative::CAP) == -1
check "scan_at with negative start -> reject", Kiln::HttpNative.kiln_http_scan_at(data, data.bytesize, -1, 5, scratch, Kiln::HttpNative::CAP) == -1

puts "-- Response: body without copy"
big_body = "z" * 100_000
check "payload returns original body object", Kiln::Response.payload(200, big_body).equal?(big_body)
utf_body = "привет"
wire = Kiln::Response.build_wire(200, Kiln::Headers.new, utf_body, false)
check "non-ASCII body is serialized byte-for-byte", wire.end_with?(utf_body.b) && wire.include?("Content-Length: 12\r\n")

puts "-- C byte checks compared with regexes"
hosts = ["example.com", "example.com:8080", "a", "[::1]", "[::1]:80", "[fe80::1%25eth0]", "[v1.addr]", "[vF.a:b]",
         "[]", "[::1", "::1]", "host:", "host:abc", ":80", "", "x y", "x%41", "x%4", "x%GG", "[v.x]", "[v1.]",
         "[1.2.3.4]:65535", "under_score.example", "a-b.c~d!$&'()*+,;=", "a/b", "a@b", "[::1]x", "[::1]:", "%41%42"]
pieces = %w[a Z 0 9 . - _ ~ ! $ & ' ( ) * + , ; = % : [ ] v V / @ \s].map(&:b) + [" ".b, "\t".b]
seed = 777
3000.times do
  seed = (seed * 1_103_515_245 + 12_345) % 2_147_483_648
  text = (+"").b
  (1 + seed % 9).times do
    seed = (seed * 1_103_515_245 + 12_345) % 2_147_483_648
    text << pieces[(seed >> 8) % pieces.size]
  end
  hosts << text
end
host_bad = hosts.count { |h| Kiln::HttpSyntax.valid_host?(h.b) != Kiln::HttpNative.host?(h.b) }
check "Host: C matches regex on #{hosts.size} inputs", host_bad == 0
tokens = ["Content-Type", "X-A", "a!#$%&'*+.^_`|~-", "", "Bad Name", "x:y", "кир", "a\tb", "X_1"]
check "token: C matches regex", tokens.all? { |t| t.b.match?(Kiln::HttpSyntax::TOKEN) == Kiln::HttpNative.token?(t.b) }
ctls = ["plain", "a\tb", "a\x00b", "a\x7fb", "привет", "", "a\r", "\x1f"]
check "ctl: C matches regex", ctls.all? { |t| t.b.match?(Kiln::HttpSyntax::CTL) == Kiln::HttpNative.ctl?(t.b) }
nums = ["0", "1", "10", "007", "", "-1", "5abc", "123456789", " 5"]
check "digits: C matches regex", nums.all? { |t| t.b.match?(Kiln::HttpSyntax::CL_NUM) == Kiln::HttpNative.digits?(t.b) }

puts "-- Pool: kill at different stages"
phase_pool = Kiln::Pool.new(2, validate: ->(c) { Kernel.sleep 0.002; true },
                               close: ->(c) { Kernel.sleep 0.002 }) { Kernel.sleep 0.002; Conn.new(5) }
victims = []
200.times do |k|
  victims << Thread.new do
    phase_pool.with(timeout: 2) { |c| k % 3 == 0 ? raise(IOError, "drop") : Kernel.sleep(0.001 * (k % 4)) }
  rescue IOError, Kiln::PoolTimeout
    nil
  end
  victims[k - 2].kill if k >= 2 && k % 3 != 1
  Kernel.sleep 0.001 if k % 5 == 0
end
victims.each { |th| th.join(3) }
check "after kill during factory/validate/block/close: invariant and quarantine", phase_pool.consistent? && phase_pool.available + phase_pool.quarantined == 2

puts "-- HTTP: limits"
check "Content-Length longer than 9 digits with large max_body", Kiln::HttpSyntax.content_length({ "content-length" => "2000000000" }, 3_000_000_000) == 2_000_000_000
check "Content-Length exceeds max_body -> too_long", Kiln::HttpSyntax.content_length({ "content-length" => "3000000001" }, 3_000_000_000) == :too_long
bad_cfg = [{ max_conns: 0 }, { read_timeout: 0 }, { request_timeout: -1 }, { write_timeout: 0 }, { kill_grace: -0.1 }, { max_body: -1 },
           { read_timeout: Float::INFINITY }, { kill_grace: Float::INFINITY }, { request_timeout: 0.0 / 0.0 }]
rejected = bad_cfg.count do |cfg|
  begin
    Kiln::Server.new(nil, nil, log: nil, port: 0, **cfg)
    false
  rescue ArgumentError
    true
  end
end
check "invalid server options are rejected (#{bad_cfg.size})", rejected == bad_cfg.size

puts "-- Pool: deterministic interruptions (test holds pool mutex)"
dp = Kiln::Pool.new(1) { Conn.new(9) }
dlock = dp.instance_variable_get(:@lock)
inside = Queue.new
release = Queue.new
user = Thread.new { dp.with { |c| inside << true; release.pop; c.n } }
inside.pop
dlock.lock
release << true
finished = !user.join(0.5).nil?
dlock.unlock
check "resource return does not wait for pool mutex", finished && user.value == 9 && dp.consistent? && dp.checked_out == 0 && dp.available == 1
dlock.lock
blocked = Thread.new { dp.with(timeout: 2) { |c| c.n } }
Kernel.sleep 0.1
blocked.kill
blocked.join(1)
dlock.unlock
check "kill while waiting for checkout mutex leaves accounting unchanged", dp.consistent? && dp.checked_out == 0 && dp.available == 1 && dp.with { |c| c.n } == 9
r = begin
      Kiln::Pool.new(1, max_lifetime: Float::INFINITY) { Conn.new(1) }
      :accepted
    rescue ArgumentError
      :rejected
    end
check "infinite max_lifetime is rejected", r == :rejected
check "after stage stress: open == idle + out; no resource remains checked out", phase_pool.consistent? && phase_pool.checked_out == 0

puts "-- Pool: physical capacity during close"
live = Queue.new
peak = Queue.new
gate = Queue.new
phys = Kiln::Pool.new(1, discard: ->(_e) { true }, close: ->(_c) { gate.pop; live.pop }) do
  live << 1
  peak << live.size
  Conn.new(live.size)
end
closer = Thread.new do
  phys.with { raise IOError, "drop" }
rescue IOError
  :dropped
end
Kernel.sleep 0.1
check "slot remains occupied while resource is closing", phys.closing == 1 && phys.available == 0 && phys.consistent?
waiter = Thread.new { phys.with(timeout: 2) { |c| c.n } }
Kernel.sleep 0.1
check "second request waits instead of opening an extra resource", waiter.alive? && live.size == 1
gate << true
closer.join
check "second request gets new resource after close", waiter.value == 1 && phys.closing == 0 && phys.consistent?
max_live = 0
max_live = [max_live, peak.pop].max until peak.empty?
check "live resources never exceed size", max_live == 1
failing = Kiln::Pool.new(1, discard: ->(_e) { true }, close: ->(_c) { raise IOError, "close failed" }) { Conn.new(1) }
r = begin
      failing.with { raise IOError, "drop" }
    rescue IOError
      :dropped
    end
check "close failure is counted and slot remains quarantined", r == :dropped && failing.close_failures == 1 && failing.available == 0 && failing.quarantined == 1 && failing.consistent?
stale_failed = Kiln::Pool.new(1, validate: ->(_c) { false }, close: ->(_c) { raise FatalPoolError, "stale close interrupted" }) { Conn.new(1) }
stale_failed.with { |c| c.n }
r = begin
      stale_failed.with { |c| c.n }
    rescue FatalPoolError
      :interrupted
    end
check "stale-close counts fatal error and keeps slot", r == :interrupted && stale_failed.close_failures == 1 && stale_failed.quarantined == 1 && stale_failed.available == 0 && stale_failed.consistent?

ordered = Kiln::Pool.new(1, discard: ->(_e) { true }, close: ->(_c) { true }) { Conn.new(1) }
begin
  ordered.with { raise IOError, "discard" }
rescue IOError
  nil
end
events = ordered.instance_variable_get(:@events)
close_started = events.pop
close_finished = events.pop
dead = Thread.new { true }
dead.join
close_started[1].thread = dead
events << close_started
check "close start without result keeps slot occupied", ordered.closing == 0 && ordered.quarantined == 1 && ordered.available == 0 && ordered.close_abandoned == 1 && ordered.consistent?
events << close_finished
events << close_finished
check "late and duplicate close result is applied once", ordered.available == 1 && ordered.closing == 0 && ordered.quarantined == 0 && ordered.consistent?

