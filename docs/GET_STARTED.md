# Get Started

This guide covers installation, server setup, routing, controllers, request
data, streaming, database access, and the other user-facing Kiln APIs. For a
short project overview, see [README.md](../README.md).

## Install

Install the system build dependencies first. On Debian/Ubuntu:

```sh
sudo apt-get update
sudo apt-get install build-essential cmake git curl ruby ruby-dev pkg-config libffi-dev libssl-dev libpq-dev zlib1g-dev
```

On macOS, install the Xcode Command Line Tools and Homebrew, then:

```sh
brew install cmake pkg-config libffi libpq openssl@3
```

The Kiln wrappers discover these Homebrew pkg-config directories automatically.
Kiln::DB needs libpq 17+; upgrade older distribution packages before building.
Kiln builds its tested MariaDB Connector/C revision automatically for both
MySQL and MariaDB. No separate Connector/C installation is needed.

From the Kiln checkout:

```sh
bin/setup
cd ..
kiln/bin/spin new my_app
cd my_app
../kiln/bin/spin add kiln --path ../kiln
../kiln/bin/spin build
KILN_WORKERS=2 ./build/bin/my_app
```

Put application code in `my_app/bin/my_app.rb`. Use `../kiln/bin/spin build`
to rebuild or `../kiln/bin/spin run` to build and run. The Kiln directory can
live elsewhere; adjust that path accordingly.

`bin/setup` fetches the exact commit in `ci/spinel-ref`, applies every
`patches/spinel/*.patch` with `git apply --check` followed by `git apply`,
builds Spinel and installs it under `.tools/spinel`. It then checks placement
of threads created from main and from another thread with 3 and 5 workers.
The first build needs network access and takes longer; a matching installed
toolchain is reused without fetching anything. Setup also builds Connector/C
under `.tools/mariadb`, using the commit in `ci/mariadb-ref` and verifying
the downloaded archive against `ci/mariadb-source.sha256`. This revision
reports version 3.4.12; it is an exact upstream commit, not a floating release.
`.tools/` is local build output. Git and Docker ignore it.
Builds use an OS file lock, which is released if the builder is interrupted.
A later setup can continue without removing lock directories by hand.

`bin/spin` and `bin/spinel` also bootstrap a missing or stale toolchain and
validate its build recipe and compiler/runtime checksums before use. They use
this local installation regardless of a global Spinel on `PATH`. A failing
patch stops the build. Set an absolute `KILN_SPINEL_PREFIX` to use another
installation directory, and use the same value for setup and later commands.
Set `SPINEL_CC` to select the C compiler, for example `SPINEL_CC=clang`.

For `build`, `run` and `test`, `bin/spin` also records the toolchain in
`build/.kiln-toolchain`. The Connector/C fingerprint and library path also
participate. On a mismatch or missing stamp it moves prior
`build/bin` and `build/test` into `build/.kiln-previous.*`, so timestamp-based
checks cannot reuse executables from a different runtime. Matching builds
keep Spinel's incremental behavior. The previous outputs remain under the
ignored `build/` directory.

Package C objects use `.tools/native-cache/<fingerprint>`, so a runtime,
client or compiler change also bypasses old objects with future timestamps.
`SPIN_NATIVE_CACHE` chooses the parent cache directory; the wrapper adds the
fingerprint beneath it.

`spin add kiln` only adds a dependency; upstream Spinel does not run Kiln's
setup or patch an already installed compiler. Use the Kiln wrappers shown
above for the managed toolchain. An explicit `SPINEL` in low-level test and
benchmark scripts is an expert override; CI requires the managed installation.

`bin/spin build` compiles a portable native build without an additional trust step.
The optimized manual build (`ext/build.sh`) retains runtime-dispatched SIMD for
zlib-ng and picohttpparser. Both build paths are checked separately in CI.
Both paths include Kiln::DB by default; see [Database](#database).

## Server

```ruby
require "kiln"

router = Kiln::Routing::Router.new
router.get("/", ->(ctx) { ctx.res.text("Hello, world!\n") })
router.seal!

log = Kiln::Observability::Log.new
app = Kiln::Middleware::Rescue.new(router, log)
server = Kiln::Server.new(app, log: log, host: "127.0.0.1", port: 8080)
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

Without `host:` the server listens on all interfaces (`0.0.0.0`) on both
backends. Pass `host: "127.0.0.1"` to accept only local connections, for
example behind a reverse proxy on the same machine.

Set `KILN_WORKERS` when starting the application:

```sh
KILN_WORKERS=2 ./build/bin/my_app
KILN_WORKERS=4 ./build/bin/my_app
```

The value counts application CPU workers: 2 means two, 4 means four. The
managed runtime provides its main and scheduler threads separately. This also
works with `KILN_WORKERS=4 ../kiln/bin/spin run`; the value is read at runtime,
so changing it does not require recompilation. Without it, Spinel detects the
available CPUs, including Linux affinity and container CPU quotas.
`Kiln::Runtime.workers` reports the application worker budget.

Standard settings follow that budget automatically. The event backend uses
16 concurrent handlers per CPU worker; the default database pool has the same
capacity and opens connections lazily. Base uses one accounting shard per CPU
worker. Start with these defaults; there is no `N+1` calculation and no need
to set `handlers` or pool size for ordinary startup.

These are bounded concurrency defaults, not a promise of linear throughput.
Database latency, its connection limit, query cost and client concurrency
still affect results. The standard event server starts one independent network
loop per application worker, sharing the listening socket inside one process. Explicit small
connection, stream, handshake or handler limits can reduce the loop count.
`server.loops` reports the count.
Kiln does not spawn or supervise child processes.

`backend: :base` selects the thread-per-connection engine. `handlers: N`
overrides event handler concurrency; `handlers: 0` runs handlers inline on
the event loop. A free handler takes the next request of any connection, and
requests of one connection run in order. With handler threads, an expired
`request_timeout` produces a 504 and replaces that handler. Inline handlers
share the event loop, so a waiting database operation is unsupported and a
blocking call delays other connections. Work already done by a handler
cannot be rolled back.

Explicit handler counts, pool sizes and `shards:` remain available for
workloads needing different resource limits. `SPINEL_WORKERS` is a low-level
upstream override with its original semantics; `KILN_WORKERS` takes precedence.
Use `KILN_WORKERS` for applications. `SPINEL_SCHED_STATS=2` is an optional
placement diagnostic, not required setup.

## Listeners

```ruby
tls = Kiln::Transport::Tls.new(cert: "cert.pem", key: "key.pem")
server = Kiln::Server.new(router, log: log, listen: [
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
device still match; it leaves replaced paths and inherited socket paths alone. `Kiln::Transport::Listen.fd(n)` duplicates a socket that is already listening;
the caller retains ownership of the supplied descriptor.
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

A connection takes up to 16 pipelined requests ahead of its responses. When
256 KiB of its responses are still unsent, the event server stops reading,
parsing, and starting handlers for that connection until less than 64 KiB is
left. A request the server rejects (400 or 501) is answered after the
responses to the requests before it, and the connection then closes.

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
server = Kiln::Server.new(router, log: log, host: "127.0.0.1", port: 8080)
begin
  server.run(grace: 5.0)
ensure
  log.close
end
```

Compile and run the entry point with `app/` on Spinel's require path so the
router module and controller files resolve:

```sh
../kiln/bin/spinel $(../kiln/bin/spin flags) -I app app/main.rb -o app_server
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

Path segments are percent-decoded before routes are matched, so
`/%61dmin/stats` reaches `/admin/stats`. A `*path` parameter never contains a
`.` or `..` segment or a `/` decoded from `%2F`; a `:name` parameter is one
decoded segment and can contain `/`, `.` or `..`, so check it before using it
in a file path. A proxy that allows or denies requests by the raw path (HAProxy
`path_beg`, for example) sees `/%61dmin` and not `/admin`: check access in the
handler, or normalize the path at the proxy.

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
`cookie` read the URL query and `Cookie` header. Repeated `Cookie` header
fields are joined with `; `, so each cookie keeps its own name.

An absolute-form request target (`GET http://example.com/path HTTP/1.1`)
replaces the `Host` header, as RFC 9112 requires. `Host` and every other header
come from the client: compare them with a list of known hosts before using them
for access decisions or absolute URLs.

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
A body up to `buffer_body` is read before the handler runs, so a request with
`Expect: 100-continue` and such a body gets `100 Continue` at once. For a
streamed body, `100 Continue` is sent when the handler first reads the body; a
handler that answers without reading never sends it. When a handler answers
without reading all of a streamed body, the rest is discarded so the connection
stays open if it is at most 256 KiB; a larger rest, or a body the client
announced with `Expect`, closes the connection after the response. On the event
backend a body that has already been read in full when the handler answers also
keeps the connection open. With
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

A browser handshake carries `Origin`. By default (`origins: nil`) it has to
name the request host and port: `https://example.com` matches
`Host: example.com` or `Host: example.com:443`. On an HTTPS connection the
origin has to be HTTPS as well, so an HTTP page cannot open a socket to the
HTTPS endpoint of the same host. An HTTPS origin is accepted on a plain-HTTP
connection, so the default also works behind a proxy that terminates TLS.
Any other origin, including `null`, gets 403.
`origins: ["https://app.example.com"]` accepts exactly the listed origins
(ignoring case) and `origins: ["*"]` accepts any. A handshake without `Origin`
(a non-browser client) is accepted. Behind a proxy that rewrites `Host`,
forward the original host and port (nginx
`proxy_set_header Host $http_host;`) or list the origins.

`ctx.res.upgrade("protocol") { |conn| ... }` answers `101 Switching Protocols`
with `Upgrade: protocol` and hands the connection to the block;
`ctx.res.hijack { |conn| ... }` hands it over without writing anything. `conn`
has `read(max, timeout:)` (a String, `""` when the timeout passes, nil at end
of stream or once the server shuts down), `write`, `close` and `closed?`.
Bytes the client sent right after the upgrade request are not lost. Without
`timeout:`, `read` waits at most `idle_timeout:` seconds (default 60) for
data; when none arrives it marks `conn` closed and returns nil, and the
connection is released when the block returns. This limits each read; it is
not a separate reaper, so a block that keeps running without reading keeps
its connection. Pass `idle_timeout:` to `upgrade` or `hijack` to change the
limit, or `idle_timeout: nil` to wait without one. WebSocket connections are
not affected: they use `ping_interval:`. Upgraded connections count towards
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
server = Kiln::Server.new(router, log: log, host: "127.0.0.1", port: 8080)
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

## Cache

`Kiln::Cache` is an in-process key-value cache whose entries live in C memory,
outside the Spinel heap, so a large cache does not make garbage collection
slower. Create it once, before the server starts, and share it between
handlers and threads:

```ruby
pages = Kiln::Cache.new(max_entries: 100_000, max_bytes: 256 << 20)

router.get("/articles/:id", lambda { |ctx|
  id = ctx.req.params["id"]
  ctx.res.text(pages.fetch("article:#{id}", ttl: 30) { render_article(id) })
})
```

- `get(key)` / `cache[key]` returns a copy of the stored bytes as a binary
  String, or `nil`. Call `force_encoding` if you need the text encoding back.
- `set(key, value, ttl: nil)` / `cache[key] = value` stores a copy of a
  String and returns `true`, or `false` when the value is larger than
  `max_value` (1 MiB by default), allocation fails, or the shard cannot make
  room within its 64-entry eviction budget. A failed `set` can evict up to 64
  entries, and removes the previous value of the same key. `ttl:` is in seconds; a ttl of
  `Kiln::Cache::MAX_TTL` (2^40 seconds) or more is stored as that maximum.
- `fetch(key, ttl: nil) { ... }` returns the cached value or stores the
  block's result. Two threads that miss at the same time both run the block.
- `sweep(budget = 1024)` looks at up to `budget` entries, split over the
  shards, and removes the expired ones; `sweep(0)` does nothing. Expired
  entries are also removed when they are read or evicted.
- `delete(key)`, `clear`, `stats` (`entries`, `bytes`, `hits`, `misses`,
  `evictions`, `expirations`, `refusals`).
- `close` may be called while other threads use the cache. It waits for calls
  already inside the cache, then frees it; any later call, including one
  another thread had already started in Ruby, raises `IOError`. A cache opened
  later never answers for a closed one.

Keys are converted with `to_s` and are at most 64 KiB. `max_entries` is at
most `Kiln::Cache::MAX_ENTRIES` (2^28). `max_bytes` counts keys, values and
56 bytes of overhead per entry. The hash index is allocated up front, 10 to
20 bytes per allowed entry, and is not counted. The cache is split into
`shards:` (16 by default, a power of two up to 256) with one lock each; each
shard gets an equal share of `max_entries` and `max_bytes`, so a shard can
evict before the cache as a whole is full. When a shard is full, the entry to
evict is chosen with SIEVE: entries read since the last pass are kept. A
process can have up to 64 open caches.

In a threaded build, each OS thread that reads a cache value retains a result
buffer sized for its largest read until that thread exits. Set `max_value:` to
the largest value the application needs to read.

`get`, `set` and `delete` first try the shard lock in a plain native call.
Only when another thread holds that shard does the call repeat as a
`blocking: true` call, which waits for the mutex outside the Spinel GC world,
so a garbage collection never waits for a thread queued on a cache lock and an
uncontended call does not pay for the scheduler lock that `blocking: true`
takes. Creating a cache, `sweep`, `clear`, `stats` and `close` are always
blocking. Statistics are copied into C thread-local storage and read back
without a loop, so another green thread cannot overwrite them in between.
`closed?` asks the native registry, so a copy of the wrapper sees a close too.
`max_bytes` and sweep budgets must fit a signed 64-bit C long.

`bench/cache_bench.rb` and `bench/cache_server.rb` default to 16 shards for
both stores. Native values are always copied on reads and writes. The Hash
baseline returns shared values by default (`COPY=0`); use `STORE=hash COPY=1`
for the same value-copy behavior. The benchmark output and server startup
record `copy`, alongside the store and shard count. Keep these settings,
capacity, key distribution, value size, workers and threads equal when
comparing runs. Hash uses FIFO eviction; the native cache uses SIEVE.

## Database

Kiln::DB remains experimental and is included in standard builds. It needs
libpq 17+ and the managed MariaDB Connector/C headers at build time and loads
the libraries at runtime. `bin/setup` and the build wrappers prepare Connector/C
automatically. See [DB.md](../DB.md#building).

Connect the database in `main.rb` before starting the server. This example
uses PostgreSQL; use `KIND_MY` for MySQL or MariaDB.

```ruby
require "kiln"
require "kiln/db"

pool = Kiln::DB::Pool.new(timeout: 1.0) do
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
server = Kiln::Server.new(router, log: log, host: "127.0.0.1", port: 8080)
begin
  server.run(grace: 5.0)
ensure
  pool.close
  log.close
end
```

Set `DB_HOST`, `DB_USER`, `DB_PASSWORD`, `DB_NAME` and `DB_CA` (the CA file
that signed the server certificate); `DB_PORT` defaults to `5432`. TLS with
certificate and host name verification is the default. Database calls work with the standard event handler pool or the base backend.
Explicit inline mode (`handlers: 0`) raises `Kiln::DB::Unsupported`. Each request thread leases its own connection, and a
query stops at the request deadline. See [DB.md](../DB.md) for adapters, model
declarations, query examples, and result shapes.

## Tests

```sh
bin/setup
SPINEL_WORKERS=1 ./test-spinel.sh
ci/db-offline.sh
```

Do not use `spin test --regen`. Output is written to
`/tmp/kiln-validation/tests/`. Set `KILN_VALIDATION_DIR` to change that.

## CI

`ci/run.sh` is the one CI entry point: it runs the suite with
`SPINEL_WORKERS=1`, then a short benchmark (`SAMPLE=0`) and checks its
performance and memory tables. Toolchain probes separately use 3 and 5
workers. Linux x86_64
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

## Updating Spinel

Change only `ci/spinel-ref` to the full upstream commit SHA, then run
`bin/setup`. Local builds, Docker and macOS CI all call
`ci/build-spinel.sh`; no second revision needs updating. Docker copies only
the toolchain inputs before its build step. The macOS cache key includes the
revision file, builder, C wrapper and patch contents, and restored toolchains
are checked even on a cache hit.

If a patch no longer applies, the build fails before `make`. Review the new
scheduler and update the patch, or remove it once the same fixes exist
upstream. A successful textual application alone does not prove correct
placement: rerun `bin/setup`, `ci/toolchain-test.sh`, `ci/run.sh` and the Base
and database scaling checks for the new runtime. With no `.patch` files, the
builder compiles unmodified upstream.

An installed toolchain records its commit and input hashes in
`share/kiln-spinel/recipe` and compiler/runtime hashes in
`share/kiln-spinel/payload`. `ci/build-spinel.sh --check` verifies them;
`--fingerprint` prints the expected recipe hash. Spinel's `--version` alone
does not distinguish the patched runtime. Existing application binaries must
be rebuilt after a runtime change.
