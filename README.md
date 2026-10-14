# kiln

HTTP/1.1 server for Spinel. Version 0.0.3. Behavior and measurements are in
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
threads; `handlers: 0` keeps them on the event loop. With `handlers: N`, a
handler that passes its `request_timeout` gets a 504 response, and its worker
is replaced so other requests can continue. Inline handlers share the event
loop: blocking calls delay all connections and cannot be forcibly timed out
without interrupting the loop itself. Work already done by a handler cannot
be rolled back.

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

## Compression

```ruby
app = Kiln::Compress.new(router, level: 2, stream_level: 1, min_size: 1024)
```

`Kiln::Compress` gzips text, JSON, JavaScript, XML and SVG responses of at
least `min_size` bytes when the client accepts gzip, and every stream of those
types; `out.flush`, `out.event` and `out.comment` push the compressed bytes at
once, so SSE is not held back. Compressed streams use chunked framing and do
not keep a declared `Content-Length`. It sets `Vary: Accept-Encoding`, weakens
a strong `ETag` and drops `Accept-Ranges`, and leaves 204, 206, 304, responses
that already have a `Content-Encoding`, and `Cache-Control: no-transform`
alone. Compression uses a vendored zlib-ng.

Wrap only routes that need compression when small responses dominate:

```ruby
router.scope("/api", wrap: ->(nxt) { Kiln::Compress.new(nxt) }) do |api|
  api.get("/report", Reports.method(:show))
end
```

Do not compress responses that combine secrets with reflected user input over
HTTPS. Set `Cache-Control: no-transform` on a response to disable this
middleware for that response. The event backend allows up to 1024 active
streams by default; set `max_streams:` to adjust the limit. Requests that exceed
it receive 503. The base backend uses its `max_conns` limit for concurrent
streams.

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
```

Do not use `spin test --regen`. Output is written to
`/tmp/kiln-validation/tests/`. Set `KILN_VALIDATION_DIR` to change that.

## CI

`ci/run.sh` is the one CI entry point: it runs the suite with
`SPINEL_WORKERS=1`, then a short benchmark (`SAMPLE=0`) and checks its
performance and memory tables. Every job uses one Spinel worker. Linux x86_64
(`ubuntu-24.04`) and Linux ARM64 (`ubuntu-24.04-arm`) run it in the image built
from `Dockerfile`, which holds only the toolchain; the source is mounted at
`/src`. macOS runners cannot run Docker (no nested virtualization), so
`.github/workflows/ci-macos.yml` runs the same script natively.

The same run locally, on any machine with Docker (on Apple silicon this is the
linux/arm64 job of CI):

```sh
docker build -t kiln-ci .
docker run --rm --user "$(id -u):$(id -g)" -v "$PWD:/src" kiln-ci ci/run.sh
```

`CI_BENCH` (default `1`), `KILN_ARTIFACTS` (default `$TMPDIR/kiln-ci`) and
`TEST_TIMEOUT` adjust a run.
