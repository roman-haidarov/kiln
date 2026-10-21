# Get Started

This guide covers installation, server setup, routing, controllers, request
data, streaming, database access, and the other user-facing Kiln APIs. For a
short project overview, see [README.md](../README.md).

## Install

```sh
spin add kiln --path ../kiln
spin build
```

`spin build` compiles a portable native build without an additional trust step.
The optimized manual build (`ext/build.sh`) retains runtime-dispatched SIMD for
zlib-ng and picohttpparser. Both build paths are checked separately in CI.
Neither path compiles Kiln::DB unless it is requested; see [Database](#database).

## Server

```ruby
require "kiln"

router = Kiln::Routing::Router.new
router.get("/", ->(ctx) { ctx.res.text("Hello, world!\n") })
router.seal!

log = Kiln::Observability::Log.new
app = Kiln::Middleware::Rescue.new(router, log)
server = Kiln::Server.new(app, nil, log: log, host: "127.0.0.1", port: 8080)
begin
  server.run(grace: 30.0)
ensure
  log.close
end
```

A handler reads `ctx.req` and writes `ctx.res`. `ctx.sleep`, `ctx.all`,
`ctx.first`, and `Kiln::Runtime.pause` follow the request deadline. `run` waits for
INT or TERM, then shuts the server down. Pass `tasks:` to stop a `Kiln::Runtime::Tasks`
in the same grace period. `start` and `shutdown(grace:)` are for a process
that handles signals itself.

Kiln does not spawn or supervise child processes: configure Spinel M:N
parallelism via `SPINEL_WORKERS`, and use a process supervisor outside Kiln
if independent processes or rolling upgrades are required.

`backend: :base` selects the thread-per-connection engine. The event backend
runs handlers inline by default. `handlers: N` runs handlers on N worker
threads; `handlers: 0` keeps them on the event loop. With `handlers: N`, a
handler that passes its `request_timeout` gets a 504 response, and its worker
is replaced so other requests can continue. Inline handlers share the event
loop: blocking calls delay all connections and cannot be forcibly timed out
without interrupting the loop itself. Work already done by a handler cannot
be rolled back.

## Listeners

```ruby
tls = Kiln::Transport::Tls.new(cert: "cert.pem", key: "key.pem")
server = Kiln::Server.new(router, nil, log: log, listen: [
  Kiln::Transport::Listen.tcp("0.0.0.0", 8443, tls: tls),
  Kiln::Transport::Listen.tcp("0.0.0.0", 8080),
  Kiln::Transport::Listen.unix("/run/app.sock", mode: 0o660)
], backlog: 1024, tcp_nodelay: true)
```

`listen:` takes `Kiln::Transport::Listen` values or strings: `"127.0.0.1:8080"`,
`"[::1]:8080"`, `"unix:/run/app.sock"` and `"fd:3"`. Without `listen:` the
server uses `host:` and `port:` (and `tls:` for that one listener).
`server.ports` lists the bound ports in `listen:` order (0 for a unix socket).
A unix socket file left by a dead process is replaced only if connecting
to it returns `ECONNREFUSED`; other errors do not authorize removal. On
shutdown, the server unlinks its original socket path only if the inode and
device still match; it leaves replaced paths and inherited socket paths alone. `Kiln::Transport::Listen.fd(n)` serves a socket that is already listening, and
`Kiln::Transport::Listen.systemd` returns the sockets passed by systemd socket activation
or `listenfd` (`LISTEN_FDS`/`LISTEN_PID`). `reuse_port: true` sets
`SO_REUSEPORT`, so independently started servers can bind a **fixed** shared TCP port.
It cannot be combined with TCP `port: 0` (an ephemeral port).

A peer that resets the connection while a response is being written must not
end the process. Listening and accepted sockets get `SO_NOSIGPIPE` where the
platform has it (macOS, BSD), and `start` sets `SIGPIPE` to ignored if it still
has the default disposition, as Spinel's `TCPServer.new` does. A handler the
program installed itself is left alone. Compression uses a vendored zlib-ng; on x86-64 (SSE2 to AVX2,
PCLMULQDQ) and arm64 (NEON, CRC32, PMULL with EOR3) it picks the fastest
routines the CPU supports at run time. Building the extension with
`KILN_EXT_CFLAGS="-O2 -DKILN_GENERIC"` keeps the portable C routines only, for
compression and for request parsing; Valgrind needs that build, because it
does not implement the SSE4.2 string instructions picohttpparser uses.

### TLS

`Kiln::Transport::Tls.new(cert:, key:, ca: nil, verify: :none, ciphers: "", ciphersuites:
"", min_version: "1.2", alpn: ["http/1.1"])` describes a certificate chain and
private key in PEM files. TLS runs inside the event loop over the system
OpenSSL 1.1.1 or 3.x, which kiln loads when the program starts a TLS listener;
nothing links against it at build time. Set `KILN_LIBSSL` and `KILN_LIBCRYPTO`
to load a specific library. `Kiln::Transport::Tls.available?` reports whether it was
found. ALPN selects the first protocol of `alpn:` that the client offers; a
client that offers only protocols kiln does not speak (for example only `h2`)
fails the handshake with `no_application_protocol`, as Go's `crypto/tls` does.
`verify: :optional` or `:require` asks for a client certificate signed by
`ca:`. `ctx.req.scheme` is `"https"` on a TLS listener, `ctx.req.tls?` is
true and `ctx.req.alpn` names the negotiated protocol. `max_connection_rate:`
(default 256) bounds the TLS handshakes in progress per process; above it the
listener stops accepting until a handshake finishes. This is a **concurrent handshake**
limit, not a rate per second. TLS
needs the event backend.

## Timeouts

| option | default | meaning |
| --- | --- | --- |
| `header_timeout` | `read_timeout` | from accept (or the first byte of a later request) to the end of its head; the client gets 408 |
| `keep_alive_timeout` | `read_timeout` | idle time between requests; `0` closes after every response |
| `read_timeout` | 5.0 | each wait for request body bytes, and a buffered body after its head |
| `request_timeout` | 2.0 | the handler deadline (`ctx.deadline`) |
| `write_timeout` | 10.0 | a response write that makes no progress |
| `client_disconnect_timeout` | 1.0 (base: 0.5) | after a response that closes the connection, how long kiln keeps reading and discarding before it closes, so the client sees the response and not a reset |

## Routes

Keep route declarations in router modules and request logic in controllers:

```text
app/
  main.rb
  controllers/users.rb
  routers/users.rb
  controllers/posts.rb
  routers/posts.rb
```

`app/controllers/users.rb`:

```ruby
module Controllers
  class Users < Kiln::Routing::Controller
    def index = res.text("users")
    def show = res.text("User #{params['id']}")
    def create = res.text("created", status: 201)
    def search = res.text("search #{req.query_params['q']}")
    def ban = res.text("banned #{params['id']}")
  end
end
```

`app/routers/users.rb`:

```ruby
require "controllers/users"

module Routers
  module Users
    def self.configure(router)
      router.get("/users/search", ->(ctx) { Controllers::Users.new(ctx).search })
      router.post("/users/:id/ban", ->(ctx) { Controllers::Users.new(ctx).ban })
      router.resources("/users", {
        index: ->(ctx) { Controllers::Users.new(ctx).index },
        show: ->(ctx) { Controllers::Users.new(ctx).show },
        create: ->(ctx) { Controllers::Users.new(ctx).create }
      })
    end
  end
end
```

`app/main.rb`:

```ruby
require "kiln"
require "routers/users"
require "routers/posts"

router = Kiln::Routing::Router.new
router.configure(Routers::Users)
router.configure(Routers::Posts)
router.seal!
log = Kiln::Observability::Log.new($stdout)
server = Kiln::Server.new(router, nil, log: log, host: "127.0.0.1", port: 8080)
begin
  server.run(grace: 5.0)
ensure
  log.close
end
```

Compile and run the entry point with `app/` on Spinel's require path so the
router module and controller files resolve:

```sh
spinel -I app app/main.rb -o app_server
./app_server
```

`resources` accepts `index`, `show`, `create`, `update` (PUT and PATCH), and
`destroy`. The router module maps each action to a handler. `configure` lets
`main.rb` compose router modules without containing their route definitions.
For a larger application, put each API area in its own router file. Require each
module in `main.rb`, configure all of them on the same `Kiln::Routing::Router`, then call
`seal!` once after the last module. Each module adds its routes to that shared
router; the application still starts one server with the composed router.

For example, `app/routers/posts.rb` can follow the same pattern:

```ruby
require "controllers/posts"

module Routers
  module Posts
    def self.configure(router)
      router.get("/posts", ->(ctx) { Controllers::Posts.new(ctx).index })
    end
  end
end
```

## Controllers

Each route handler creates a controller for that request. Controllers contain
request logic and private helpers, with no route table or route registration
code. Custom paths use the same `get`, `post`, `put`, `patch` and `delete`
methods as every other route. Register static paths such as `/users/search`
before `resources("/users", ...)`, so they take precedence over `/users/:id`.
Keep controller action lambdas in application router modules; Kiln should not
generate action-dispatch lambdas, because they can make Spinel fail to compile
programs that do not use that shortcut.

```ruby
router = Kiln::Routing::Router.new(trailing_slash: :redirect)
router.get("/files/*path", ->(ctx) { ctx.res.text(ctx.req.params["path"]) })
router.get("/health", ->(ctx) { ctx.res.text("ok") })
router.not_found(->(ctx) { ctx.res.json_value({ "error" => "not found" }, status: 404) })
router.method_not_allowed(->(ctx) { ctx.res.json_value({ "allow" => ctx.res.headers["Allow"] }, status: 405) })
router.scope("/admin") do |admin|
  admin.get("/stats", ->(ctx) { ctx.res.text("stats") })
end
router.seal!
```

## Request data

```ruby
router = Kiln::Routing::Router.new
router.post("/users", lambda { |ctx|
  input = ctx.req.json
  ctx.res.set_cookie("seen", "1", max_age: 3600)
  ctx.res.json_value({ "name" => input["name"], "page" => ctx.req.query_params["page"],
                       "session" => ctx.req.cookie("sid") }, status: 201)
})
router.seal!
```

Send this route JSON with `Content-Type: application/json`; `query_params` and
`cookie` read the URL query and `Cookie` header.

`ctx.req.form` reads an `application/x-www-form-urlencoded` body.
`Kiln::HTTP::Json.parse` and `Kiln::HTTP::Json.generate` are the direct calls. Inside a
request, `Kiln::Runtime.pop(queue)` waits on a queue only until the deadline.

## Streaming

```ruby
router = Kiln::Routing::Router.new
router.get("/export", lambda { |ctx|
  ctx.res.stream(type: "text/csv") do |out|
    out.write("id,name\n")
    out.write("1,Ada\n")
  end
})

router.get("/events", lambda { |ctx|
  ctx.res.sse do |out|
    out.event("ready", event: "status")
  end
})
router.seal!
```

The block runs after the handler returns, while the response is written, so
`request_timeout` limits the handler and `write_timeout` limits each write.
`out.write` buffers up to 16 KiB; `out.flush`, `out.event`, and `out.comment`
send at once. `out.closed?` turns true when the client has gone or the server
is shutting down. A write to a client that has gone raises `Kiln::Runtime::ClientGone`.

## Request bodies

A body up to `buffer_body` bytes (default `max_body`) is read before the
handler runs, as before. A larger body, and every `Transfer-Encoding: chunked`
body, is streamed: the handler starts when the head arrives and reads the body
while the client sends it.

```ruby
router = Kiln::Routing::Router.new
router.post("/upload", lambda { |ctx|
  size = 0
  ctx.req.payload.each { |chunk| size += chunk.bytesize }
  ctx.res.text("#{size}\n")
}, limit: 64 << 20)
router.scope("/api", limit: 64 << 10) do |api|
  api.post("/items", ->(ctx) { ctx.res.json_value(ctx.req.json, status: 201) })
end
router.seal!
```

`ctx.req.payload` reads at most 64 KiB per `read`; `each` yields every chunk
and `read_all` returns the rest as one String. `ctx.req.body`, `json` and
`form` read the whole streamed body. `buffer_body` must be no larger than
`max_body`; per-route `limit:` can still exceed `max_body` for streamed routes.
The socket stops being read while the
handler is behind, so a slow handler holds at most a few hundred KiB per
connection. `limit:` on a route or a scope replaces `max_body` for its routes:
a declared `Content-Length` over the limit gets 413 before the handler runs,
and a chunked body that grows past it raises `Kiln::HTTP::PayloadTooLarge` (413)
when it is read. A chunk size too large to represent gets 413 as well, on both
backends. `ctx.req.limit_body(n)` lowers it inside a handler. A body
that stalls for `read_timeout` raises `Kiln::HTTP::RequestTimeout` (408).
`Expect: 100-continue` is answered when the handler first reads the body; a
handler that answers without reading never sends it. An unread body up to 256
KiB is discarded so the connection stays open; a larger one, or one the client
announced with `Expect`, closes the connection after the response. With
`handlers: 0` a request with a streamed body runs on its own thread so the
event loop keeps serving other connections.

## Upgrades and WebSocket

```ruby
router = Kiln::Routing::Router.new
router.get("/chat", lambda { |ctx|
  ctx.res.websocket(ctx, protocols: ["chat"], ping_interval: 30.0) do |ws|
    ws.each do |message|
      message.text? ? ws.send_text("echo: #{message.data}") : ws.send_binary(message.data)
    end
  end
})
router.seal!
```

`ctx.res.websocket` checks the handshake (`GET`, `Upgrade: websocket`,
version 13, a valid key; otherwise 400, 405 or 426), answers 101 and runs the
block with a `Kiln::HTTP::WebSocket` once the response is sent. `receive` and `each`
return text and binary messages (fragments joined, text checked as UTF-8) and
answer pings; `send_text`, `send_binary`, `ping` and `close(code, reason)`
send frames. Protocol errors close with 1002, invalid UTF-8 (in a text message
or a close reason) with 1007 and a
message over `max_message` (1 MiB) with 1009. With `ping_interval:` kiln pings
an idle peer and drops one that does not answer within the next interval.
Server shutdown closes open sockets with 1001.

`ctx.res.upgrade("protocol") { |conn| ... }` answers `101 Switching Protocols`
with `Upgrade: protocol` and hands the connection to the block;
`ctx.res.hijack { |conn| ... }` hands it over without writing anything. `conn`
has `read(max, timeout:)` (a String, `""` when the timeout passes, nil at end
of stream or once the server shuts down), `write`, `close` and `closed?`. Bytes the client sent right after
the upgrade request are not lost. Upgraded connections count towards
`max_streams` on the event backend and end when the block returns.

## Static files

Put files under `public/` before starting the server; the route parameter
`*path` selects a file below that directory.

```ruby
router = Kiln::Routing::Router.new
assets = Kiln::Static.new("public", max_age: 3600)
router.get("/", assets)
router.get("/assets/*path", assets)
router.seal!
```

`Kiln::Static` serves files under its root with `Content-Type` by extension,
`ETag`, `Last-Modified`, conditional requests (304 and 412), and single byte
ranges (206 and 416). A directory serves its `index.html`; there are no
listings. Dotfiles, and symlinks that lead out of the root, answer 404. Files
over 256 KiB are streamed with their `Content-Length`.
Symlinks to dotfiles also answer 404. An open file descriptor keeps a stream
on the file selected for its response even if its path changes.
`Kiln::HTTP::Conditional.precondition` and `Kiln::HTTP::Conditional.window` apply the same
rules to any handler that has an ETag.

`ctx.res.stream(length: n) { |out| ... }` sends `Content-Length: n` instead of
chunked framing; writing more than `n` bytes raises `ArgumentError`, and
writing fewer closes the connection.

## Compression

```ruby
router = Kiln::Routing::Router.new
router.scope("/api", wrap: ->(nxt) { Kiln::Middleware::Compress.new(nxt, min_size: 1024) }) do |api|
  api.get("/report", ->(ctx) { ctx.res.json_value({ "status" => "ready" }) })
end
router.seal!
```

`Kiln::Middleware::Compress` gzips text, JSON, JavaScript, XML and SVG responses of at
least `min_size` bytes when the client accepts gzip, and every stream of those
types; `out.flush`, `out.event` and `out.comment` push the compressed bytes at
once, so SSE is not held back. Compressed streams use chunked framing and do
not keep a declared `Content-Length`. It sets `Vary: Accept-Encoding`, weakens
a strong `ETag` and drops `Accept-Ranges`, and leaves 204, 206, 304, responses
that already have a `Content-Encoding`, and `Cache-Control: no-transform`
alone.

Do not compress responses that combine secrets with reflected user input over
HTTPS. Set `Cache-Control: no-transform` on a response to disable this
middleware for that response. The event backend allows up to 1024 active
streams by default; set `max_streams:` to adjust the limit. Requests that exceed
it receive 503. The base backend uses its `max_conns` limit for concurrent
streams.

## Tasks

```ruby
log = Kiln::Observability::Log.new
tasks = Kiln::Runtime::Tasks.new(log)
tasks.every("heartbeat", 60.0) { |_token| log.info("still running") }

router = Kiln::Routing::Router.new
router.get("/", ->(ctx) { ctx.res.text("Hello, world!\n") })
router.seal!
server = Kiln::Server.new(router, nil, log: log, host: "127.0.0.1", port: 8080)
begin
  server.run(grace: 30.0, tasks: tasks)
ensure
  log.close
end
```

## Middleware

```ruby
router = Kiln::Routing::Router.new
router.get("/health", ->(ctx) { ctx.res.text("ok") })
router.seal!

app = Kiln::Middleware::Cors.new(
  Kiln::Middleware::DefaultHeaders.new(router, { "X-Content-Type-Options" => "nosniff" }),
  origins: ["https://app.example"],
  headers: %w[Content-Type],
  expose: %w[X-Request-Id],
  credentials: true
)
```

## Calling a handler

```ruby
router = Kiln::Routing::Router.new
router.get("/users/:id", ->(ctx) { ctx.res.json_value({ "id" => ctx.req.params["id"] }) })
router.post("/users", ->(ctx) { ctx.res.json_value(ctx.req.json, status: 201) })
router.seal!
get = Kiln::Testing.call(router, "GET", "/users/7?full=1", headers: { "Cookie" => "sid=1" })
post = Kiln::Testing.json(router, "POST", "/users", { "name" => "Ann" })
```

`get.status` and `get.body` and `post.status` and `post.body` contain the
responses produced by those handlers.

## Pools

Provide a resource factory and replace the sample work with your application
operations:

```ruby
pool = Kiln::Runtime::Pool.new(4) { connect_to_service }
result = pool.with(timeout: 1.0) { |connection| connection.query("SELECT 1") }

cpu = Kiln::Runtime::CpuPool.new(2, queue: 16)
value = cpu.run(timeout: 0.5) { expensive_calculation }
cpu.shutdown(grace: 1.0)
```

## Database

Kiln::DB is experimental in 0.0.8 and is not compiled by `spin build`. Build it
with `KILN_DB=1 ./ext/build.sh` (see [DB.md](../DB.md#building)); it needs
libpq 17+ and MariaDB Connector/C 3.4+ headers at build time and loads the
libraries at run time.

Connect the database in `main.rb` before starting the server. This example
uses PostgreSQL; use `KIND_MY` for MySQL or MariaDB.

```ruby
require "kiln"
require "kiln/db"

pool = Kiln::DB::Pool.new(4, timeout: 1.0) do
  Kiln::DB::Conn.open(
    Kiln::DB::Native::KIND_PG,
    ENV["DB_HOST"], (ENV["DB_PORT"] || "5432").to_i,
    ENV["DB_USER"], ENV["DB_PASSWORD"], ENV["DB_NAME"],
    ENV.fetch("DB_CA"), ENV["DB_TLS_NAME"] || ENV["DB_HOST"]
  )
end
Kiln::DB::Scope.pool = pool

router = Kiln::Routing::Router.new
router.get("/health", ->(ctx) { ctx.res.text("ok") })
router.seal!
log = Kiln::Observability::Log.new($stdout)
server = Kiln::Server.new(router, nil, log: log, host: "127.0.0.1", port: 8080, handlers: 4)
begin
  server.run(grace: 5.0)
ensure
  pool.close
  log.close
end
```

Set `DB_HOST`, `DB_USER`, `DB_PASSWORD`, `DB_NAME` and `DB_CA` (the CA file
that signed the server certificate); `DB_PORT` defaults to `5432`. TLS with
certificate and host name verification is the default. Database calls need
`handlers: N` (or the base backend): on an inline event-loop handler they raise
`Kiln::DB::Unsupported`. Each request thread leases its own connection, and a
query stops at the request deadline. See [DB.md](../DB.md) for adapters, model
declarations, query examples, and result shapes.

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
