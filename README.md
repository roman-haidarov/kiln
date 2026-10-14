# kiln

HTTP/1.1 server for Spinel. Version 0.0.2. Behavior and measurements are in
[CHANGELOG.md](CHANGELOG.md). Recorded checks are in
[VALIDATION.md](VALIDATION.md).

## Install

```sh
spin add kiln --path ../kiln
```

`spin build` compiles `ext/` with the C compiler from the environment.

## Server

```ruby
require "kiln"

router = Kiln::Router.new
  .get("/", ->(ctx) { ctx.res.text("Hello, world!\n") })
  .namespace("/api") { |api| api.configure(Api::Users) }
  .seal!

log = Kiln::Log.new($stdout)
app = Kiln::Rescue.new(router, log)
server = Kiln::Server.new(app, nil, log: log, host: "127.0.0.1", port: 8080)
server.run(grace: 30.0)
log.close
```

A handler reads `ctx.req` and writes `ctx.res`. `ctx.sleep`, `ctx.all`,
`ctx.first`, and `Kiln.pause` follow the request deadline. `run` waits for
INT or TERM, then shuts the server down. Pass `tasks:` to stop a `Kiln::Tasks`
in the same grace period. `start` and `shutdown(grace:)` are for a process
that handles signals itself.

`backend: :base` selects the thread-per-connection engine. The event backend
runs handlers inline by default. `handlers: N` runs handlers on N worker
threads; `handlers: 0` keeps them on the event loop. A handler that passes its
`request_timeout` gets a 504 response, and its worker is replaced so other
requests can continue. Work already done by that handler cannot be rolled
back.

## Routes

```ruby
module Api
  module Users
    class << self
      def configure(router)
        router.resources("/users", {
                           index: method(:index), show: method(:show), create: method(:create)
                         })
      end

      def index(ctx) = ctx.res.text("Users")
      def show(ctx) = ctx.res.text("User #{ctx.req.params["id"]}")
      def create(ctx) = ctx.res.text("created", status: 201)
    end
  end
end
```

`resources` accepts `index`, `show`, `create`, `update` (PUT and PATCH), and
`destroy`. Pass only the actions the module implements.

```ruby
router = Kiln::Router.new(trailing_slash: :redirect)
router.get("/files/*path", ->(ctx) { ctx.res.text(ctx.req.params["path"]) })
router.get("/health", ->(ctx) { ctx.res.text("ok") })
router.not_found(->(ctx) { ctx.res.json_value({ "error" => "not found" }, status: 404) })
router.method_not_allowed(->(ctx) { ctx.res.json_value({ "allow" => ctx.res.headers["Allow"] }, status: 405) })
router.scope("/admin", wrap: ->(nxt) { AdminOnly.new(nxt) }) do |admin|
  admin.get("/stats", Stats.method(:show))
end
router.seal!
```

## Request data

```ruby
router.post("/users", lambda { |ctx|
  input = ctx.req.json
  page = ctx.req.query_params["page"]
  sid = ctx.req.cookie("sid")
  ctx.res.set_cookie("seen", "1", max_age: 3600)
  ctx.res.json_value({ "id" => 1, "name" => input["name"] }, status: 201)
})
```

`ctx.req.form` reads an `application/x-www-form-urlencoded` body.
`Kiln::Json.parse` and `Kiln::Json.generate` are the direct calls. Inside a
request, `Kiln.pop(queue)` waits on a queue only until the deadline.

## Streaming

```ruby
router.get("/export", lambda { |ctx|
  ctx.res.stream(type: "text/csv") do |out|
    Report.each_row { |row| out.write(row.to_csv) }
  end
})

router.get("/events", lambda { |ctx|
  ctx.res.sse do |out|
    until out.closed?
      out.event(Clock.now.to_s, event: "tick")
      Kernel.sleep 1
    end
  end
})
```

The block runs after the handler returns, while the response is written, so
`request_timeout` limits the handler and `write_timeout` limits each write.
`out.write` buffers up to 16 KiB; `out.flush`, `out.event`, and `out.comment`
send at once. `out.closed?` turns true when the client has gone or the server
is shutting down. A write to a client that has gone raises `Kiln::ClientGone`.

## Static files

```ruby
assets = Kiln::Static.new("public", max_age: 3600)
router.get("/", assets)
router.get("/assets/*path", assets)
```

`Kiln::Static` serves files under its root with `Content-Type` by extension,
`ETag`, `Last-Modified`, conditional requests (304 and 412), and single byte
ranges (206 and 416). A directory serves its `index.html`; there are no
listings. Dotfiles, and symlinks that lead out of the root, answer 404. Files
over 256 KiB are streamed with their `Content-Length`.
Symlinks to dotfiles also answer 404. An open file descriptor keeps a stream
on the file selected for its response even if its path changes.
`Kiln::Conditional.precondition` and `Kiln::Conditional.window` apply the same
rules to any handler that has an ETag.

`ctx.res.stream(length: n) { |out| ... }` sends `Content-Length: n` instead of
chunked framing; writing more than `n` bytes raises `ArgumentError`, and
writing fewer closes the connection.

## Tasks

```ruby
tasks = Kiln::Tasks.new(log)
tasks.every("cache sweep", 60.0) { |_token| Cache.sweep }
tasks.spawn("consumer") do |token|
  until token.cancelled?
    job = queue.pop(timeout: 1.0)
    process(job) if job
  end
end
server.run(grace: 30.0, tasks: tasks)
```

## Middleware

```ruby
app = Kiln::Cors.new(
  Kiln::DefaultHeaders.new(router, { "X-Content-Type-Options" => "nosniff" }),
  origins: ["https://app.example"],
  headers: %w[Content-Type],
  expose: %w[X-Request-Id],
  credentials: true
)
```

## Calling a handler

```ruby
res = Kiln::Testing.call(app, "GET", "/users/7?full=1", headers: { "Cookie" => "sid=1" })
res = Kiln::Testing.json(app, "POST", "/users", { "name" => "Ann" })
```

`res.status` and `res.body` are what the handler wrote.

## Pools

```ruby
pool = Kiln::Pool.new(4) { connect_to_service }
result = pool.with(timeout: 1.0) { |connection| connection.query("SELECT 1") }

cpu = Kiln::CpuPool.new(2, queue: 16)
value = cpu.run(timeout: 0.5) { expensive_calculation }
cpu.shutdown(grace: 1.0)
```

## Tests

```sh
SPINEL=/path/to/spinel SPINEL_WORKERS=1 ./test-spinel.sh
SPINEL_WORKERS=2 ./test-spinel.sh
```

Do not use `spin test --regen`. Output is written to
`/tmp/kiln-validation/tests/`. Set `KILN_VALIDATION_DIR` to change that.
