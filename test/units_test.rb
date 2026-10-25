require 'kiln'
require 'stringio'
require 'test/support'

def check(label, passed)
  raise "FAIL #{label}" unless passed

  puts "ok   #{label}"
end

def raises(label, klass)
  yield
  raise "FAIL #{label}: nothing raised"
rescue klass
  check(label, true)
end

def route_call(router, verb, path)
  req = Kiln::HTTP::Request.new(verb, path, {}, nil)
  res = Kiln::HTTP::Response.new
  router.call(Kiln::Routing::Context.new(req, res, 'route', 0.0))
  [req, res]
end

def native_matches(label, samples, pattern)
  check(label, samples.all? { |sample| sample.b.match?(pattern) == yield(sample.b) })
end

class Conn
  attr_reader :n

  def initialize(number) = @n = number
end

class AppError < StandardError; end
class FatalPoolError < Exception; end

puts '-- Runtime::Pool'
made = Queue.new
closed = Queue.new
pool = Kiln::Runtime::Pool.new(1, close: ->(c) { closed << c.n }) do
  made << 1
  Conn.new(made.size)
end
first = pool.with(&:n)
begin
  pool.with { |_c| raise AppError, 'bad sql' }
rescue AppError
  nil
end
check 'application error does not recreate resource', pool.with(&:n) == first && made.size == 1
begin
  pool.with { |_c| raise IOError, 'broken pipe' }
rescue IOError
  nil
end
check 'IO failure: resource replaced and old resource closed', pool.with(&:n) == 2 && closed.size == 1
entered = Queue.new
t = Thread.new do
  pool.with do |_c|
    entered << true
    Kernel.sleep 5
  end
end
check 'task acquired resource before kill', entered.pop(timeout: 1) == true
t.kill
t.join
check 'kill inside with: resource replaced', pool.available == 1 && pool.with(&:n) == 3
entered = Queue.new
holder = Thread.new do
  pool.with do |_c|
    entered << true
    Kernel.sleep 0.3
  end
end
check 'pool holder acquired resource', entered.pop(timeout: 1) == true
r = begin
  pool.with(timeout: 0.05) { |_c| :got }
rescue Kiln::Runtime::PoolTimeout
  :timeout
end
holder.join
check 'empty pool -> Runtime::PoolTimeout', r == :timeout
check 'with returns block value', pool.with { |_c| 42 } == 42
bad_discard = Kiln::Runtime::Pool.new(1, discard: ->(_e) { raise AppError, 'discard failed' }) { Conn.new(1) }
r = begin
  bad_discard.with { raise IOError, 'broken' }
rescue IOError => e
  e.message
end
check 'discard failure preserves slot and original error', r == 'broken' && bad_discard.available == 1
calls = Queue.new
lazy = Kiln::Runtime::Pool.new(3) do
  calls << 1
  Conn.new(calls.size)
end
check 'factory is not called when pool is created', calls.empty? && lazy.available == 3
lazy.with(&:n)
lazy.with(&:n)
check 'resource is reused instead of recreated', calls.size == 1
failing = Kiln::Runtime::Pool.new(1) { raise AppError, 'db down' }
r = begin
  failing.with { |c| c }
rescue AppError => e
  e.message
end
check 'factory error during checkout restores capacity', r == 'db down' && failing.available == 1
r = begin
  Kiln::Runtime::Pool.new(1) { nil }.with { |c| c }
rescue ArgumentError => e
  e.message
end
check 'factory cannot return nil', r == 'pool factory returned no resource'
validated_closed = Queue.new
validated = Kiln::Runtime::Pool.new(1, close: ->(c) { validated_closed << c.n }, validate: lambda { |_c|
  raise FatalPoolError, 'validation interrupted'
}) { Conn.new(301) }
validated.with(&:n)
r = begin
  validated.with(&:n)
rescue FatalPoolError
  :interrupted
end
check 'interrupt during validate closes checked-out resource and restores capacity',
      r == :interrupted && validated_closed.size == 1 && validated.available == 1
closing_calls = Queue.new
closing = Kiln::Runtime::Pool.new(1, discard: ->(_e) { true },
                                     close: ->(_c) { raise FatalPoolError, 'close interrupted' }) do
  closing_calls << true
  Conn.new(closing_calls.size)
end
r = begin
  closing.with { raise IOError, 'broken' }
rescue FatalPoolError
  :interrupted
end
check 'interrupt during close keeps slot quarantined',
      r == :interrupted && pool_holds?(closing, available: 0, quarantined: 1, failures: 1)
r = begin
  closing.with(timeout: 0.02, &:n)
rescue Kiln::Runtime::PoolTimeout
  :timeout
end
check 'no new resource is created after interrupted close', r == :timeout && closing_calls.size == 1
born = Queue.new
aged = Kiln::Runtime::Pool.new(1, max_lifetime: 0.05, close: ->(c) { closed << c.n }) do
  born << 1
  Conn.new(100 + born.size)
end
first_aged = aged.with(&:n)
Kernel.sleep 0.08
second_aged = aged.with(&:n)
check 'max_lifetime: expired resource is closed and replaced', first_aged == 101 && second_aged == 102
healthy = Queue.new
checked = Kiln::Runtime::Pool.new(1, validate: ->(c) { c.n != 201 }) do
  healthy << 1
  Conn.new(200 + healthy.size)
end
checked.with(&:n)
check 'validate: rejected resource is replaced', checked.with(&:n) == 202

puts '-- HTTP::Response'
res = Kiln::HTTP::Response.new
res.text('secret', status: 204)
wire = res.to_wire(true)
check '204 sends no body or Content-Length',
      wire.end_with?("\r\n\r\n") && !wire.include?('Content-Length') && !wire.include?('secret')
res.text('secret', status: 304)
wire = res.to_wire(true)
check '304 sends no body', wire.end_with?("\r\n\r\n") && !wire.include?('secret')
res.text('secret', status: 205)
wire = res.to_wire(true)
check '205 sends zero length and no body', wire.include?("Content-Length: 0\r\n") && wire.end_with?("\r\n\r\n")
res.status = 100
res.body = 'secret'
res.headers['X-Leak'] = 'secret'
wire = res.to_wire(true)
check 'informational status cannot be sent as final response',
      wire.start_with?('HTTP/1.1 500 ') && wire.end_with?("internal error\n") &&
      !wire.include?('X-Leak') && !wire.include?('secret')
headers = Kiln::HTTP::Headers.new
headers['Content-Type'] = 'text/plain'
headers['X-Bad'] = "a\r\nb"
payload = 'hello'
wire = Kiln::HTTP::Response.build_wire(200, headers, payload, false)
check 'response formatting does not modify input', headers['Content-Type'] == 'text/plain' && payload == 'hello'
check 'unsafe header is rejected on insertion',
      wire.include?("Content-Type: text/plain\r\n") && !wire.include?('X-Bad:') && !headers.key?('X-Bad')
caller_name = +'X-Ok'
caller_value = +'fine'
owned = Kiln::HTTP::Headers.new
owned[caller_name] = caller_value
stored_value = owned['X-Ok']
caller_name << '-Renamed'
caller_value << '-tampered'
owned_wire = Kiln::HTTP::Response.build_wire(200, owned, 'z', false)
check 'stored header cannot be changed after insertion',
      stored_value == 'fine' && !stored_value.equal?(caller_value) &&
      owned_wire.include?("X-Ok: fine\r\n") && !owned_wire.include?('tampered') &&
      !owned_wire.include?('Renamed')
stored_value << "\r\nX-Injected: 1"
injected_wire = Kiln::HTTP::Response.build_wire(200, owned, 'z', false)
check 'a stored header changed to carry CR or LF never reaches the wire',
      !injected_wire.include?('X-Injected') &&
      (!injected_wire.include?('X-Ok:') || injected_wire.include?("X-Ok: fine\r\n"))
custom_name = +'X-Custom-Name'
named = Kiln::HTTP::Headers.new
named[custom_name] = 'v'
named['Content-Type'] = 'text/plain'
yielded = []
named.each { |name, _value| yielded << name }
again = []
named.each { |name, _value| again << name }
yielded[0].replace('Content-Length')
named_wire = Kiln::HTTP::Response.build_wire(200, named, 'z', false)
check 'each returns detached header names that cannot rename stored headers',
      !yielded[0].equal?(again[0]) && !custom_name.frozen? && custom_name == 'X-Custom-Name' &&
      named_wire.include?("X-Custom-Name: v\r\n") && !named_wire.include?("Content-Length: v\r\n")
date_first = Kiln::HTTP::Date.value
date_copy = Kiln::HTTP::Date.value
date_copy << "\r\nX-Date-Injected: 1"
dated_wire = Kiln::HTTP::Response.build_wire(200, Kiln::HTTP::Headers.new, 'z', false)
check 'HTTP::Date.value is a copy; changing it never reaches the wire',
      !dated_wire.include?('X-Date-Injected') && dated_wire.include?("\r\nDate: ") && !date_copy.frozen? &&
      !date_first.equal?(date_copy)
dated = Kiln::HTTP::Headers.new
dated['DATE'] = 'custom'
wire = Kiln::HTTP::Response.build_wire(200, dated, 'ok', false)
check 'Date header is recognized case-insensitively',
      wire.scan(/(?:\A|\r\n)Date:/i).size == 1 && wire.include?("DATE: custom\r\n")

r = begin
  Kiln::Server::Base.new(nil, log: nil, port: 0, coop_budget: -1)
  :accepted
rescue ArgumentError
  :rejected
end
check 'coop_budget rejects negative values', r == :rejected
check 'both engines default to the loopback address',
      Kiln::Server::Settings.base({}).host == '127.0.0.1' && Kiln::Server::Settings.event({}).host == '127.0.0.1'
log_path = "/tmp/kiln-log-flush-#{Process.pid}.log"
log_file = File.open(log_path, 'w')
file_log = Kiln::Observability::Log.new(log_file)
file_log.info('flushed line')
log_limit = Kiln::Runtime.now + 2
Kernel.sleep 0.01 until File.read(log_path).include?('flushed line') || Kiln::Runtime.now > log_limit
log_seen = File.read(log_path)
file_log.close
log_file.close
File.delete(log_path)
check 'Log writes a line out before it is closed', log_seen.include?('flushed line')

puts '-- HTTP syntax'
head = "GET /items/42 HTTP/1.1\r\nHost: example.org\r\nAccept: text/plain\r\nAccept: application/json".b
parsed = Kiln::HTTP::Syntax.parse_head(head)
check 'header parsing does not modify input string', head.include?("Accept: text/plain\r\nAccept: application/json")
check 'repeated headers are combined',
      parsed[0] == '1.1' && parsed[1] == 'GET' && parsed[2] == '/items/42' &&
      parsed[3]['accept'] == 'text/plain, application/json'
cookie_head = "GET / HTTP/1.1\r\nHost: x\r\nCookie: a=1\r\nCookie: b=2".b
syntax_cookie = Kiln::HTTP::Syntax.parse_head(cookie_head)
native_cookie = Kiln::HTTP::Native.parse_head(cookie_head, Kiln::HTTP::Native.scratch)
check 'repeated Cookie uses a semicolon in both parsers',
      syntax_cookie[3]['cookie'] == 'a=1; b=2' && native_cookie[3]['cookie'] == 'a=1; b=2'
check 'empty WebSocket payload has a two-byte frame header',
      Kiln::HTTP::WebSocket.header(1, 0) == "\x81\x00".b
check 'WebSocket frame headers use the minimal length encoding at each boundary',
      Kiln::HTTP::WebSocket.header(1, 125) == "\x81\x7D".b &&
      Kiln::HTTP::WebSocket.header(1, 126) == "\x81\x7E\x00\x7E".b &&
      Kiln::HTTP::WebSocket.header(1, 255) == "\x81\x7E\x00\xFF".b &&
      Kiln::HTTP::WebSocket.header(1, 512) == "\x81\x7E\x02\x00".b &&
      Kiln::HTTP::WebSocket.header(1, 65_535) == "\x81\x7E\xFF\xFF".b &&
      Kiln::HTTP::WebSocket.header(2, 65_536) == "\x82\x7F\x00\x00\x00\x00\x00\x01\x00\x00".b
idle_res = Kiln::HTTP::Response.new
idle_res.upgrade('kiln-idle') { |_conn| nil }
default_idle = idle_res.tunnel_idle
idle_res.upgrade('kiln-idle', idle_timeout: nil) { |_conn| nil }
unbounded_idle = idle_res.tunnel_idle
idle_res.hijack(idle_timeout: 2) { |_conn| nil }
check 'upgrade bounds idle reads at 60 seconds unless idle_timeout says otherwise',
      default_idle == 60.0 && unbounded_idle.negative? && idle_res.tunnel_idle == 2.0
bad_idle = [0, -1.5, Float::INFINITY, 0.0 / 0.0, 10**400]
rejected_idle = bad_idle.count do |value|
  Kiln::HTTP::Response.new.upgrade('kiln-idle', idle_timeout: value) { |_conn| nil }
  false
rescue ArgumentError
  true
end
check 'idle_timeout rejects zero, negative, infinite, NaN and too large values', rejected_idle == bad_idle.size
ws_origins = Kiln::HTTP::WsOrigins
same_host = ws_origins.policy(nil)
check 'WebSocket origins default to the request host',
      ws_origins.allowed?(nil, 'x', same_host) && ws_origins.allowed?('https://x', 'x', same_host, 'https') &&
      ws_origins.allowed?('https://x:443', 'x', same_host, 'https') &&
      ws_origins.allowed?('http://x', 'x:80', same_host) &&
      ws_origins.allowed?('http://x:8080', 'x:8080', same_host) &&
      ws_origins.allowed?('HTTPS://X', 'X', same_host, 'https')
check 'WebSocket origins reject another host, port, scheme or an opaque origin',
      !ws_origins.allowed?('http://x:8080', 'x', same_host) && !ws_origins.allowed?('https://evil', 'x', same_host) &&
      !ws_origins.allowed?('null', 'x', same_host) && !ws_origins.allowed?('ftp://x', 'x', same_host) &&
      !ws_origins.allowed?('https://x', nil, same_host)
check 'WebSocket origins accept an HTTPS page behind TLS termination but no HTTP page on an HTTPS request',
      ws_origins.allowed?('https://x', 'x', same_host, 'http') &&
      ws_origins.allowed?('https://x:8443', 'x:8443', same_host, 'http') &&
      !ws_origins.allowed?('http://x', 'x', same_host, 'https') &&
      !ws_origins.allowed?('http://x:443', 'x:443', same_host, 'https')
listed_origins = ws_origins.policy(['https://A.example'])
check 'WebSocket origins match a list exactly and accept *',
      ws_origins.allowed?('https://a.example', 'x', listed_origins) &&
      !ws_origins.allowed?('https://b.example', 'x', listed_origins) &&
      ws_origins.allowed?('https://b.example', 'x', ws_origins.policy(['*']))
bad_origins = [[], 'https://a.example', [1]]
rejected_origins = bad_origins.count do |value|
  ws_origins.policy(value)
  false
rescue ArgumentError
  true
end
check 'origins rejects an empty list, a bare string and non-string entries', rejected_origins == bad_origins.size
check 'duplicate Host is rejected', Kiln::HTTP::Syntax.parse_head("GET / HTTP/1.1\r\nHost: a\r\nHost: b".b) == :bad
check 'body length limit works independently of server',
      Kiln::HTTP::Syntax.content_length({ 'content-length' => '12' }, 10) == :too_long
target, authority = Kiln::HTTP::Syntax.absolute_target('https://example.org/items/42')
check 'absolute-form extracts path and authority', target == '/items/42' && authority == 'example.org'
check 'keep-alive honors version and Connection',
      Kiln::HTTP::Syntax.persistent?('1.0', 'keep-alive') && !Kiln::HTTP::Syntax.persistent?('1.1', 'close')

puts '-- Routing::Router'
module RouterUserRoutes
  class << self
    def configure(router)
      router.scope('/api') do |api|
        api.get('/users/:id', ->(ctx) { ctx.res.text("user=#{ctx.req.params['id']}") })
      end
    end
  end
end

module RouterBookController
  class << self
    def configure(router)
      router.resources('/books', {
                         index: method(:index), show: method(:show), create: method(:create),
                         update: method(:update), destroy: method(:destroy)
                       })
    end

    def index(ctx) = ctx.res.text('index')
    def show(ctx) = ctx.res.text("show=#{ctx.req.params['id']}")
    def create(ctx) = ctx.res.text('create')
    def update(ctx) = ctx.res.text("update=#{ctx.req.params['id']}")
    def destroy(ctx) = ctx.res.text("destroy=#{ctx.req.params['id']}")
  end
end

router = Kiln::Routing::Router.new
router.get('/items/:id', ->(c) { c.res.text("get=#{c.req.params['id']}") })
router.post('/items/:id', ->(c) { c.res.text("post=#{c.req.params['id']}") })
req, res = route_call(router, 'GET', '/items/42')
check 'GET selects its route and parameters', res.body == 'get=42' && req.params['id'] == '42'
_, res = route_call(router, 'POST', '/items/43')
check 'POST selects its route', res.body == 'post=43'
_, res = route_call(router, 'HEAD', '/items/44')
check 'HEAD uses GET', res.body == 'get=44'
_, res = route_call(router, 'DELETE', '/items/45')
check '405 lists methods without duplicates', res.status == 405 && res.headers['Allow'] == 'GET, POST, HEAD'
_, res = route_call(router, 'GET', '/unknown')
check 'unknown path returns 404', res.status == 404
root_router = Kiln::Routing::Router.new
root_router.get('/', ->(c) { c.res.text('root') })
_req, res = route_call(root_router, 'GET', '/')
check 'root route is found through index', res.body == 'root'
ordered_router = Kiln::Routing::Router.new
ordered_router.get('/:section/items', ->(c) { c.res.text("dynamic=#{c.req.params['section']}") })
ordered_router.get('/shop/items', ->(c) { c.res.text('static') })
_req, res = route_call(ordered_router, 'GET', '/shop/items')
check 'dynamic first segment preserves order', res.body == 'dynamic=shop'
reverse_router = Kiln::Routing::Router.new
reverse_router.get('/shop/items', ->(c) { c.res.text('static') })
reverse_router.get('/:section/items', ->(c) { c.res.text("dynamic=#{c.req.params['section']}") })
_req, res = route_call(reverse_router, 'GET', '/shop/items')
check 'static route also preserves order', res.body == 'static'
_req, res = route_call(reverse_router, 'GET', '/other/items')
check 'dynamic route works with a new prefix', res.body == 'dynamic=other'
req, = route_call(router, 'GET', '/items/plain'.b)
check 'plain byte path is normalized to UTF-8',
      req.params['id'] == 'plain' && req.params['id'].encoding == Encoding::UTF_8
req, = route_call(router, 'GET', '/items/a%20b')
check 'percent-encoded segment is decoded', req.params['id'] == 'a b'
_req, res = route_call(router, 'GET', '/items/a%GG')
check 'invalid percent escape is rejected', res.status == 400
configured = Kiln::Routing::Router.new
                                  .scope('/api') do |api|
                                    api.scope('/v1') { |v1| v1.get('/health', ->(c) { c.res.text('ok') }) }
                                  end
  .configure(RouterUserRoutes)
check 'router chains and module scopes compose', configured.get('/unused', ->(c) { c }) == configured
_req, res = route_call(configured, 'GET', '/api/v1/health')
check 'nested scope prefixes routes', res.body == 'ok'
req, res = route_call(configured, 'GET', '/api/users/42')
check 'configure mounts module routes', res.body == 'user=42' && req.params['id'] == '42'
direct_res = Kiln::HTTP::Response.new
RouterBookController.index(Kiln::Routing::Context.new(nil, direct_res, 'resource', 0.0))
check 'resource controller procedure accepts context', direct_res.body == 'index'
resource_router = Kiln::Routing::Router.new.namespace('/api') do |api|
  api.configure(RouterBookController)
end
[
  ['GET', '/api/books', 'index'],
  ['GET', '/api/books/7', 'show=7'],
  ['POST', '/api/books', 'create'],
  ['PUT', '/api/books/7', 'update=7'],
  ['PATCH', '/api/books/7', 'update=7'],
  ['DELETE', '/api/books/7', 'destroy=7']
].each do |verb, path, expected|
  req = Kiln::HTTP::Request.new(verb, path, {}, nil)
  res = Kiln::HTTP::Response.new
  resource_router.call(Kiln::Routing::Context.new(req, res, 'resource', 0.0))
  check "resources maps #{verb} #{path}", res.body == expected
end
book_actions = { show: RouterBookController.method(:show), create: RouterBookController.method(:create) }
limited_resources = Kiln::Routing::Router.new.resources('/books', book_actions, only: [:show])
req = Kiln::HTTP::Request.new('POST', '/books', {}, nil)
res = Kiln::HTTP::Response.new
limited_resources.call(Kiln::Routing::Context.new(req, res, 'resource', 0.0))
check 'resources only registers selected actions', res.status == 404

puts '-- Routing::Context'
ctx = Kiln::Routing::Context.new(nil, nil, 't1', Kiln::Runtime.now + 0.5)
check 'all: result order preserved; nil and false are valid', ctx.all([lambda {
  Kernel.sleep 0.02
  1
}, -> {}, lambda {
  false
}]) == [1, nil, false]
r = begin
  ctx.all([lambda {
    Kernel.sleep 2
    1
  }, -> { raise AppError, 'db down' }])
rescue AppError => e
  e.message
end
check 'all: sibling error propagates immediately, not at deadline', r == 'db down'
check 'first: false is a successful result', ctx.first([-> { false }, lambda {
  Kernel.sleep 2
  true
}]) == false
r = begin
  ctx.first([-> { raise AppError, 'a' }, -> { raise AppError, 'b' }])
rescue AppError
  :error
end
check 'first: all tasks failed -> task error', r == :error
r = begin
  ctx.first([])
rescue ArgumentError
  :arg
end
check 'first: empty list -> ArgumentError', r == :arg
seen = Queue.new
ctx.all([lambda {
  seen << Thread.current[:request_id]
  seen << Kiln::Runtime.deadline.positive?
}])
check 'subtask inherits request id and deadline', seen.pop == 't1' && seen.pop == true
late = Kiln::Routing::Context.new(nil, nil, 't2', Kiln::Runtime.now - 1)
r = begin
  late.all([-> { 1 }])
rescue Kiln::Runtime::DeadlineExceeded
  :deadline
end
check 'all does not start tasks after deadline', r == :deadline
standalone = Kiln::Routing::Context.new(nil, nil, 'sleep', Kiln::Runtime.now + 0.03)
t = Kiln::Runtime.now
r = begin
  standalone.sleep(1)
rescue Kiln::Runtime::DeadlineExceeded
  :deadline
end
check 'ctx.sleep observes deadline without thread-local state', r == :deadline && Kiln::Runtime.now - t < 0.2

puts '-- Runtime::CpuPool'
cpu = Kiln::Runtime::CpuPool.new(1, queue: 1)
Thread.current[:request_id] = 'cpu-request'
rid = cpu.run { Thread.current[:request_id] }
Thread.current[:request_id] = nil
check 'CPU task inherits request id', rid == 'cpu-request' && cpu.run { Thread.current[:request_id] }.nil?
started = Queue.new
busy = Thread.new do
  cpu.run(timeout: 2) do
    started << 1
    Kernel.sleep 0.4
  end
end
check 'CPU worker started task', started.pop(timeout: 1) == 1
queued = Thread.new { cpu.run(timeout: 2) { 42 } }
limit = Kiln::Runtime.now + 1
Kernel.sleep 0.005 while cpu.queued.zero? && Kiln::Runtime.now < limit
check 'CPU queue is full', cpu.queued == 1
Thread.current[:kiln_deadline] = Kiln::Runtime.now + 0.05
r = begin
  cpu.run(timeout: 1) { 99 }
rescue Kiln::Runtime::DeadlineExceeded
  :deadline
end
Thread.current[:kiln_deadline] = nil
busy.join
queued.join
check 'full CPU queue at deadline -> Runtime::DeadlineExceeded', r == :deadline && cpu.skipped.zero?

puts '-- Runtime::Supervisor'
io = StringIO.new
log = Kiln::Observability::Log.new(io)
runs = Queue.new
sup = Kiln::Runtime::Supervisor.new(log)
sup.child('flaky') do
  runs << 1
  raise AppError, "boom #{runs.size}" if runs.size < 3

  Kernel.sleep 5
end
Kernel.sleep 0.5
check 'service retries until startup succeeds', runs.size == 3 && sup.restarts == 2
sup.stop
check 'stop does not raise', true

puts '-- Observability::Log'
log.info("line1\nERROR forged")
log.close
check 'newline cannot forge a log entry', io.string.lines.size == 3 && io.string.include?('line1 ERROR forged')
check 'no log entries were dropped', log.dropped.zero?

puts '-- Spinel guards'
class BrokenLog
  def info(_msg) = raise(IOError, 'stdout closed')
  def error(_msg) = raise(IOError, 'stdout closed')
end

class OkHandler
  def call(ctx) = ctx.res.text('fine', status: 201)
end

class FailHandler
  def call(_ctx) = raise(ArgumentError, 'boom')
end
guard_req = Kiln::HTTP::Request.new('GET', '/', {}, nil)
guard_ctx = Kiln::Routing::Context.new(guard_req, Kiln::HTTP::Response.new, 'g', 0.0)
r = begin
  Kiln::Middleware::AccessLog.new(OkHandler.new, BrokenLog.new).call(guard_ctx)
  guard_ctx.res.status
rescue Exception => e
  e.class.name
end
check 'Middleware::AccessLog: logging failure does not erase completed response', r == 201
outer = Queue.new
guard_ctx = Kiln::Routing::Context.new(guard_req, Kiln::HTTP::Response.new, 'g', 0.0)
def guarded(middleware, ctx, mark)
  middleware.call(ctx)
ensure
  mark << :ensure
end
r = begin
  guarded(Kiln::Middleware::Rescue.new(FailHandler.new, BrokenLog.new), guard_ctx, outer)
  guard_ctx.res.status
rescue Exception => e
  e.class.name
end
check 'Middleware::Rescue: error -> 500 without re-raise; outer ensure ran', r == 500 && outer.size == 1
made = Queue.new
gp = Kiln::Runtime::Pool.new(1) do
  made << 1
  Conn.new(made.size)
end
r = begin
  gp.with { |_c| raise AppError, 'sql' }
rescue AppError => e
  e.message
end
check 'Runtime::Pool#with: block error reaches caller and resource returns to pool', r == 'sql' && gp.available == 1
check 'Kiln::Runtime.pause returns without recursing into Kernel.sleep', Kiln::Runtime.pause(0.001).is_a?(Integer)

puts '-- Visibility and purity'
raises('HTTP::Syntax: helper functions are private', NoMethodError) { Kiln::HTTP::Syntax.encode_owned(+'x') }
raises('HTTP::PathSyntax.decode is private', NoMethodError) { Kiln::HTTP::PathSyntax.decode(+'x') }
cookies = Kiln::HTTP::Headers.new
cookies.add('Set-Cookie', 'a=1')
cookies.add('Set-Cookie', 'b=2')
cookies['content-type'] = 'text/plain'
cookies['Content-Type'] = 'application/json'
cookies['Content-Length'] = '99'
cookies['Bad Name'] = 'x'
wire = Kiln::HTTP::Response.build_wire(200, cookies, '{}', true)
check 'Set-Cookie: both values are sent', wire.include?("Set-Cookie: a=1\r\n") && wire.include?("Set-Cookie: b=2\r\n")
check '[]= replaces values case-insensitively',
      wire.scan('Content-Type:').size == 1 && wire.include?("Content-Type: application/json\r\n")
check 'managed and invalid headers are rejected',
      !wire.include?('99') && !wire.include?('Bad Name') && cookies.size == 3
path = '/a/%D0%BF/b'.b
copy = path.dup
segs = Kiln::HTTP::PathSyntax.segments(path)
check 'HTTP::PathSyntax.segments does not modify input', path == copy && path.encoding == Encoding::ASCII_8BIT
check 'HTTP::PathSyntax.segments decodes UTF-8', segs == %w[a п b] && segs[1].encoding == Encoding::UTF_8
names = Kiln::HTTP::PathSyntax.param_names(Kiln::HTTP::PathSyntax.compile('/u/:id/x/:tab'))
check 'parameter names are computed at registration', names == ['', 'id', '', 'tab']
check 'HTTP::PathSyntax.params',
      Kiln::HTTP::PathSyntax.params(names, %w[u 7 x info]) == { 'id' => '7', 'tab' => 'info' }

puts '-- HTTP::Native compared with reference HTTP::Syntax'
browser_head = "GET /products/42?ref=home HTTP/1.1\r\n" \
               "Host: shop.example.com\r\n" \
               "Connection: keep-alive\r\n" \
               "sec-ch-ua: \"Chromium\";v=\"128\", \"Not;A=Brand\";v=\"24\"\r\n" \
               "sec-ch-ua-mobile: ?0\r\n" \
               "sec-ch-ua-platform: \"macOS\"\r\n" \
               "Upgrade-Insecure-Requests: 1\r\n" \
               'User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) ' \
               'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safa' \
               "ri/537.36\r\n" \
               "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8\r\n" \
               "Sec-Fetch-Site: same-origin\r\n" \
               "Sec-Fetch-Mode: navigate\r\n" \
               "Sec-Fetch-User: ?1\r\n" \
               "Sec-Fetch-Dest: document\r\n" \
               "Referer: https://shop.example.com/\r\n" \
               "Accept-Encoding: gzip, deflate, br, zstd\r\n" \
               "Accept-Language: ru-RU,ru;q=0.9,en-US;q=0.8,en;q=0.7\r\n" \
               'Cookie: session=abc123def456; theme=dark; cart=9f8e7d6c'.b
native_out = Kiln::HTTP::Native.scratch
check 'browser request uses C fast path',
      Kiln::HTTP::Native.kiln_http_scan(browser_head, browser_head.bytesize, native_out, Kiln::HTTP::Native::CAP) == 16
common_names = Kiln::HTTP::Native::COMMON
common_lines = common_names.map { |name| "#{name.upcase}: v" }
common_head = "GET / HTTP/1.1\r\n#{common_lines.join("\r\n")}\r\nX-Other: v"
common_count = Kiln::HTTP::Native.kiln_http_scan(common_head, common_head.bytesize, native_out, Kiln::HTTP::Native::CAP)
all_known = common_names.each_index.all? { |index| native_out[9 + (5 * index)] == index }
check 'C header lookup recognizes every common name regardless of case',
      common_count == common_names.length + 1 && all_known && native_out[9 + (5 * common_names.length)] == -1
crafted = [
  "GET /health HTTP/1.1\r\nHost: x", 'GET / HTTP/1.0', "POST /a?b=1 HTTP/1.1\r\nHost: x\r\nContent-Length: 5",
  "GET /a HTTP/1.1\r\nHost: x\r\nX-A: 1\r\nX-A: 2", "GET /a HTTP/1.1\r\nHost: x\r\nHost: y",
  "GET /a HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 1", "\r\nGET /a HTTP/1.1\r\nHost: x",
  "GET  /a HTTP/1.1\r\nHost: x", "GET /a  HTTP/1.1\r\nHost: x", "GET /a HTTP/1.1 \r\nHost: x",
  "GET /a HTTP/1.2\r\nHost: x", "GET /a HTTP/2.0\r\nHost: x", "get /a HTTP/1.1\r\nHost: x",
  "GET /a HTTP/1.1\nHost: x", "GET /a HTTP/1.1\r\nHost: x\nX: y", "GET /a HTTP/1.1\r\nHost: x\r",
  "GET /a HTTP/1.1\r\n Host: x", "GET /a HTTP/1.1\r\nHost: x\r\n folded", "GET /a HTTP/1.1\r\nHost x",
  "GET /a HTTP/1.1\r\nHost : x", "GET /a HTTP/1.1\r\nBad Name: v", "GET /a HTTP/1.1\r\n: v",
  "GET /a HTTP/1.1\r\nX: a\tb", "GET /a HTTP/1.1\r\nX: \t a \t", "GET /a HTTP/1.1\r\nX:", "GET /a HTTP/1.1\r\nX:   ",
  "GET /a HTTP/1.1\r\nX: a\x01b", "GET /a\x7f HTTP/1.1\r\nHost: x", "GET /a\x00 HTTP/1.1\r\nHost: x",
  "GET /a HTTP/1.1\r\nX: \xD0\xBF\xD1\x80\xD0\xB8", "GET /a HTTP/1.1\r\nX: \xff\xfe",
  "GET /\xD0\xBF HTTP/1.1\r\nHost: x",
  "GET /a HTTP/1.1\r\nHost: x\r\n\r\nX: y", "GET /a HTTP/1.1\r\nHost: x\r\n", '', 'GET', 'GET /a'
]
many = (+"GET / HTTP/1.1\r\nHost: x").b
100.times { |i| many << "\r\nX-#{i}: v".b }
crafted << many
crafted << (many + "\r\nX-extra: v".b)
crafted << (many + "\r\nX-extra v".b)
crafted << browser_head
mismatch = crafted.count { |c| Kiln::HTTP::Syntax.parse_head(c.b) != Kiln::HTTP::Native.parse_head(c.b, native_out) }
check "constructed cases match reference (#{crafted.size})", mismatch.zero?
pieces = [' ', "\t", "\r", "\n", ':', "\x00", "\x7f", "\xff", 'A', 'a', '/', '-', "\r\n", "\r\n ", "\r\nX-D: 1",
          "\r\nHost: z", '%'].map(&:b)
bases = [browser_head, "GET /health HTTP/1.1\r\nHost: 127.0.0.1:9000".b,
         "POST /x HTTP/1.0\r\nContent-Length: 3\r\nX-A: 1\r\nX-A: 2".b]
seed = 12_345
fuzz_total = 0
fuzz_mismatch = 0
fuzz_fast = 0
4000.times do |_k|
  seed = ((seed * 1_103_515_245) + 12_345) % 2_147_483_648
  text = bases[seed % bases.size].dup
  edits = 1 + ((seed >> 8) % 3)
  edits.times do
    seed = ((seed * 1_103_515_245) + 12_345) % 2_147_483_648
    pos = (seed >> 4) % (text.bytesize + 1)
    piece = pieces[(seed >> 16) % pieces.size]
    text = case (seed >> 24) % 3
           when 0 then text.byteslice(0, pos) + piece + text.byteslice(pos, text.bytesize - pos).to_s
           when 1 then text.byteslice(0, pos) + piece + text.byteslice(pos + 1, text.bytesize).to_s
           else text.byteslice(0, pos) + text.byteslice(pos + 1, text.bytesize).to_s
           end
  end
  fuzz_total += 1
  fuzz_fast += 1 if Kiln::HTTP::Native.kiln_http_scan(text, text.bytesize, native_out, Kiln::HTTP::Native::CAP) >= 0
  fuzz_mismatch += 1 if Kiln::HTTP::Syntax.parse_head(text) != Kiln::HTTP::Native.parse_head(text, native_out)
end
check "mutation fuzzing: #{fuzz_total} cases; no mismatches", fuzz_mismatch.zero?
check "some mutations use fast path (#{fuzz_fast.positive?})", fuzz_fast.positive?

puts '-- Runtime::Pool: kill during checkout'
stress = Kiln::Runtime::Pool.new(2) { Conn.new(1) }
victims = []
300.times do |k|
  victims << Thread.new { stress.with(timeout: 1) { |_c| Kernel.sleep 0.001 * (k % 3) } }
  victims[k - 3].kill if k >= 3 && k.even?
end
victims.each { |th| th.join(2) }
check 'resources remain after 300 killed threads', stress.available == 2 && stress.with(&:n) == 1

puts '-- Routing::Router: seal and parameters'
sealed = Kiln::Routing::Router.new
sealed.get('/static', ->(c) { c.res.text('s') })
sealed.delete('/static', ->(c) { c.res.text('d') })
sealed.seal!
r = begin
  sealed.get('/late', ->(c) { c })
  :added
rescue FrozenError
  :frozen
end
check 'routes cannot be added after seal!', r == :frozen && sealed.sealed?
sreq = Kiln::HTTP::Request.new('DELETE', '/static', {}, nil)
sres = Kiln::HTTP::Response.new
sealed.call(Kiln::Routing::Context.new(sreq, sres, 's', 0.0))
check 'DELETE route and shared empty params', sres.body == 'd' && sreq.params.frozen? && sreq.params.empty?

puts '-- Runtime::Pool: boundary cases'
r = begin
  Kiln::Runtime::Pool.new(1, max_lifetime: -10) { Conn.new(1) }
  :accepted
rescue ArgumentError
  :rejected
end
check 'negative max_lifetime is rejected', r == :rejected
narrow = Kiln::Runtime::Pool.new(1) { Conn.new(7) }
held = Queue.new
release = Queue.new
holder = Thread.new do
  narrow.with do |_c|
    held << true
    release.pop
  end
end
held.pop
waiter = Thread.new { narrow.with(timeout: 5, &:n) }
Kernel.sleep 0.05
check 'second thread waits for resource', waiter.alive? && narrow.available.zero?
waiter.kill
waiter.join(1)
release << true
holder.join
check 'kill while waiting for resource does not lose capacity', narrow.available == 1 && narrow.with(&:n) == 7

puts '-- HTTP::Native: scan_at boundaries'
data = "GET / HTTP/1.1\r\nHost: x\r\n\r\n".b
scratch = Kiln::HTTP::Native.scratch
check 'scan_at within data bounds',
      Kiln::HTTP::Native.kiln_http_scan_at(data, data.bytesize, 0, data.bytesize - 4, scratch,
                                           Kiln::HTTP::Native::CAP) == 1
check 'scan_at outside data bounds -> reject',
      Kiln::HTTP::Native.kiln_http_scan_at(data, data.bytesize, 10, data.bytesize, scratch,
                                           Kiln::HTTP::Native::CAP) == -1
check 'scan_at with negative start -> reject',
      Kiln::HTTP::Native.kiln_http_scan_at(data, data.bytesize, -1, 5, scratch, Kiln::HTTP::Native::CAP) == -1

puts '-- HTTP::Response: body without copy'
big_body = 'z' * 100_000
check 'payload returns original body object', Kiln::HTTP::Response.payload(200, big_body).equal?(big_body)
utf_body = 'привет'
wire = Kiln::HTTP::Response.build_wire(200, Kiln::HTTP::Headers.new, utf_body, false)
check 'non-ASCII body is serialized byte-for-byte',
      wire.end_with?(utf_body.b) && wire.include?("Content-Length: 12\r\n")

puts '-- C byte checks compared with regexes'
hosts = ['example.com', 'example.com:8080', 'a', '[::1]', '[::1]:80', '[fe80::1%25eth0]', '[v1.addr]', '[vF.a:b]',
         '[]', '[::1', '::1]', 'host:', 'host:abc', ':80', '', 'x y', 'x%41', 'x%4', 'x%GG', '[v.x]', '[v1.]',
         '[1.2.3.4]:65535', 'under_score.example', "a-b.c~d!$&'()*+,;=", 'a/b', 'a@b', '[::1]x', '[::1]:', '%41%42']
pieces = %w[a Z 0 9 . - _ ~ ! $ & ' ( ) * + , ; = % : [ ] v V / @ \s].map(&:b) + [' '.b, "\t".b]
seed = 777
3000.times do
  seed = ((seed * 1_103_515_245) + 12_345) % 2_147_483_648
  text = (+'').b
  (1 + (seed % 9)).times do
    seed = ((seed * 1_103_515_245) + 12_345) % 2_147_483_648
    text << pieces[(seed >> 8) % pieces.size]
  end
  hosts << text
end
host_bad = hosts.count { |h| Kiln::HTTP::Syntax.valid_host?(h.b) != Kiln::HTTP::Native.host?(h.b) }
check "Host: C matches regex on #{hosts.size} inputs", host_bad.zero?
tokens = ['Content-Type', 'X-A', "a!#$%&'*+.^_`|~-", '', 'Bad Name', 'x:y', 'кир', "a\tb", 'X_1']
native_matches('token: C matches regex', tokens, Kiln::HTTP::Syntax::TOKEN) { |bytes| Kiln::HTTP::Native.token?(bytes) }
ctls = ['plain', "a\tb", "a\x00b", "a\x7fb", 'привет', '', "a\r", "\x1f"]
native_matches('ctl: C matches regex', ctls, Kiln::HTTP::Syntax::CTL) { |bytes| Kiln::HTTP::Native.ctl?(bytes) }
nums = ['0', '1', '10', '007', '', '-1', '5abc', '123456789', ' 5']
native_matches('digits: C matches regex', nums, Kiln::HTTP::Syntax::CL_NUM) do |bytes|
  Kiln::HTTP::Native.digits?(bytes)
end

puts '-- Runtime::Pool: kill at different stages'
phase_validate = lambda { |_c|
  Kernel.sleep 0.002
  true
}
phase_pool = Kiln::Runtime::Pool.new(2, validate: phase_validate, close: ->(_c) { Kernel.sleep 0.002 }) do
  Kernel.sleep 0.002
  Conn.new(5)
end
victims = []
200.times do |k|
  victims << Thread.new do
    phase_pool.with(timeout: 2) { |_c| (k % 3).zero? ? raise(IOError, 'drop') : Kernel.sleep(0.001 * (k % 4)) }
  rescue IOError, Kiln::Runtime::PoolTimeout
    nil
  end
  victims[k - 2].kill if k >= 2 && k % 3 != 1
  Kernel.sleep 0.001 if (k % 5).zero?
end
victims.each { |th| th.join(3) }
check 'after kill during factory/validate/block/close: invariant and quarantine',
      phase_pool.consistent? && phase_pool.available + phase_pool.quarantined == 2

puts '-- HTTP: limits'
check 'Content-Length longer than 9 digits with large max_body',
      Kiln::HTTP::Syntax.content_length({ 'content-length' => '2000000000' }, 3_000_000_000) == 2_000_000_000
check 'Content-Length exceeds max_body -> too_long',
      Kiln::HTTP::Syntax.content_length({ 'content-length' => '3000000001' }, 3_000_000_000) == :too_long
bad_cfg = [{ max_conns: 0 }, { read_timeout: 0 }, { request_timeout: -1 }, { write_timeout: 0 },
           { kill_grace: -0.1 }, { max_body: -1 }, { shards: 0 },
           { read_timeout: Float::INFINITY }, { kill_grace: Float::INFINITY }, { request_timeout: 0.0 / 0.0 }]
rejected = bad_cfg.count do |cfg|
  Kiln::Server::Base.new(nil, log: nil, port: 0, **cfg)
  false
rescue ArgumentError
  true
end
check "invalid server options are rejected (#{bad_cfg.size})", rejected == bad_cfg.size

puts '-- Runtime::Pool: deterministic interruptions (test holds pool mutex)'
dp = Kiln::Runtime::Pool.new(1) { Conn.new(9) }
dlock = dp.instance_variable_get(:@lock)
inside = Queue.new
release = Queue.new
user = Thread.new do
  dp.with do |c|
    inside << true
    release.pop
    c.n
  end
end
inside.pop
dlock.lock
release << true
finished = !user.join(0.5).nil?
dlock.unlock
check 'resource return does not wait for pool mutex',
      finished && user.value == 9 && dp.consistent? && dp.checked_out.zero? && dp.available == 1
dlock.lock
blocked = Thread.new { dp.with(timeout: 2, &:n) }
Kernel.sleep 0.1
blocked.kill
blocked.join(1)
dlock.unlock
check 'kill while waiting for checkout mutex leaves accounting unchanged',
      dp.consistent? && dp.checked_out.zero? && dp.available == 1 && dp.with(&:n) == 9
r = begin
  Kiln::Runtime::Pool.new(1, max_lifetime: Float::INFINITY) { Conn.new(1) }
  :accepted
rescue ArgumentError
  :rejected
end
check 'infinite max_lifetime is rejected', r == :rejected
check 'after stage stress: open == idle + out; no resource remains checked out',
      phase_pool.consistent? && phase_pool.checked_out.zero?

puts '-- Runtime::Pool: physical capacity during close'
live = Queue.new
peak = Queue.new
gate = Queue.new
phys = Kiln::Runtime::Pool.new(1, discard: ->(_e) { true }, close: lambda { |_c|
  gate.pop
  live.pop
}) do
  live << 1
  peak << live.size
  Conn.new(live.size)
end
closer = Thread.new do
  phys.with { raise IOError, 'drop' }
rescue IOError
  :dropped
end
Kernel.sleep 0.1
check 'slot remains occupied while resource is closing', pool_holds?(phys, closing: 1, available: 0)
waiter = Thread.new { phys.with(timeout: 2, &:n) }
Kernel.sleep 0.1
check 'second request waits instead of opening an extra resource', waiter.alive? && live.size == 1
gate << true
closer.join
check 'second request gets new resource after close', waiter.value == 1 && pool_holds?(phys, closing: 0)
max_live = 0
max_live = [max_live, peak.pop].max until peak.empty?
check 'live resources never exceed size', max_live == 1
failing = Kiln::Runtime::Pool.new(1, discard: ->(_e) { true }, close: ->(_c) { raise IOError, 'close failed' }) do
  Conn.new(1)
end
r = begin
  failing.with { raise IOError, 'drop' }
rescue IOError
  :dropped
end
check 'close failure is counted and slot remains quarantined',
      r == :dropped && pool_holds?(failing, failures: 1, available: 0, quarantined: 1)
stale_failed = Kiln::Runtime::Pool.new(1, validate: ->(_c) { false },
                                          close: ->(_c) { raise FatalPoolError, 'stale close interrupted' }) do
  Conn.new(1)
end
stale_failed.with(&:n)
r = begin
  stale_failed.with(&:n)
rescue FatalPoolError
  :interrupted
end
check 'stale-close counts fatal error and keeps slot',
      r == :interrupted && pool_holds?(stale_failed, failures: 1, quarantined: 1, available: 0)

ordered = Kiln::Runtime::Pool.new(1, discard: ->(_e) { true }, close: ->(_c) { true }) { Conn.new(1) }
begin
  ordered.with { raise IOError, 'discard' }
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
check 'close start without result keeps slot occupied',
      pool_holds?(ordered, closing: 0, quarantined: 1, available: 0, abandoned: 1)
events << close_finished
events << close_finished
check 'late and duplicate close result is applied once',
      pool_holds?(ordered, available: 1, closing: 0, quarantined: 0)
