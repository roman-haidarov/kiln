# Get Started

## Install

Install build dependencies. The first `bin/setup` downloads the pinned Spinel compiler and MariaDB Connector/C. Kiln::DB needs libpq 17+.

Debian/Ubuntu:

```sh
sudo apt-get update
sudo apt-get install build-essential cmake git curl ruby ruby-dev pkg-config libffi-dev libssl-dev libpq-dev zlib1g-dev
```

macOS (after installing Xcode Command Line Tools and Homebrew):

```sh
brew install cmake pkg-config libffi libpq openssl@3
```

From a checkout named `kiln`:

```sh
bin/setup
cd ..
kiln/bin/spin new my_app
cd my_app
../kiln/bin/spin add kiln --path ../kiln
```

## What to load

| Require | Use |
| --- | --- |
| `require "kiln"` | HTTP server, routing, TLS, WebSocket, static files, middleware and cache |
| `require "kiln/db"` | PostgreSQL and MySQL/MariaDB; see [DB.md](../DB.md) |
| `require "kiln/cache"` | Cache without the HTTP server |

## Server

Put this in `my_app/bin/my_app.rb`. `router` maps URLs to handlers;
`ctx.req` reads the request and `ctx.res` writes the response.

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

Build and run from `my_app/`. `KILN_WORKERS` sets the application worker count:

```sh
../kiln/bin/spin build
KILN_WORKERS=2 ./build/bin/my_app
```

## Listeners and TLS

Use `listen:` for multiple HTTP, HTTPS or Unix listeners. `Kiln::Transport::Tls` loads a PEM certificate and key.

```ruby
tls = Kiln::Transport::Tls.new(cert: "cert.pem", key: "key.pem")
server = Kiln::Server.new(router, log: log, listen: [
  Kiln::Transport::Listen.tcp("0.0.0.0", 8443, tls: tls),
  Kiln::Transport::Listen.tcp("0.0.0.0", 8080),
  Kiln::Transport::Listen.unix("/run/app.sock", mode: 0o660)
], backlog: 1024, tcp_nodelay: true)
```

## Routes and controllers

Keep route registration in router modules and request logic in controllers. Compose modules on one router, then call `seal!`.

Directory layout:

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

`app/controllers/posts.rb`:

```ruby
module Controllers
  class Posts < Kiln::Routing::Controller
    def index = res.text("posts")
  end
end
```

`app/routers/posts.rb`:

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

Compile with `app/` on the require path:

```sh
../kiln/bin/spinel $(../kiln/bin/spin flags) -I app app/main.rb -o app_server
./app_server
```

## Route options

Use scopes, custom paths and fallback handlers when needed.

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

Use `ctx.req.json` for `Content-Type: application/json`; query parameters and cookies come from the request.

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

## Streaming

Use `stream` for incremental output and `sse` for server-sent events.

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

## Uploads

Read large or chunked request bodies through `ctx.req.payload`; `limit:` sets a route body limit.

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

## WebSocket

`websocket` upgrades a route. Browser origins must match the request host unless you configure `origins:`.

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

## Static files

`Kiln::Static` serves files under a chosen directory.

```ruby
router = Kiln::Routing::Router.new
assets = Kiln::Static.new("public", max_age: 3600)
router.get("/", assets)
router.get("/assets/*path", assets)
router.seal!
```

## Compression

Wrap routes with `Kiln::Middleware::Compress` to gzip eligible responses.

```ruby
router = Kiln::Routing::Router.new
router.scope("/api", wrap: ->(nxt) { Kiln::Middleware::Compress.new(nxt, min_size: 1024) }) do |api|
  api.get("/report", ->(ctx) { ctx.res.json_value({ "status" => "ready" }) })
end
router.seal!
```

## Background tasks

`Kiln::Runtime::Tasks` runs scheduled work; pass it to `server.run` for graceful shutdown.

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

Wrap the router, then pass the resulting `app` to `Kiln::Server.new`.

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

## Call a handler in a test

`Kiln::Testing` runs routes without opening a socket.

```ruby
router = Kiln::Routing::Router.new
router.get("/users/:id", ->(ctx) { ctx.res.json_value({ "id" => ctx.req.params["id"] }) })
router.post("/users", ->(ctx) { ctx.res.json_value(ctx.req.json, status: 201) })
router.seal!
get = Kiln::Testing.call(router, "GET", "/users/7?full=1", headers: { "Cookie" => "sid=1" })
post = Kiln::Testing.json(router, "POST", "/users", { "name" => "Ann" })
```

## Pools

Use a resource pool for connections or a CPU pool for bounded background work. Replace the placeholder operations with your own.

```ruby
pool = Kiln::Runtime::Pool.new(4) { connect_to_service }
result = pool.with(timeout: 1.0) { |connection| connection.query("SELECT 1") }

cpu = Kiln::Runtime::CpuPool.new(2, queue: 16)
value = cpu.run(timeout: 0.5) { expensive_calculation }
cpu.shutdown(grace: 1.0)
```

## Cache

`Kiln::Cache` stores bounded in-process values in native memory; `fetch` fills a missing value.

```ruby
pages = Kiln::Cache.new(max_entries: 100_000, max_bytes: 256 << 20)

router.get("/articles/:id", lambda { |ctx|
  id = ctx.req.params["id"]
  ctx.res.text(pages.fetch("article:#{id}", ttl: 30) { render_article(id) })
})
```

## Database

Add `require "kiln/db"` for PostgreSQL or MySQL/MariaDB. Create the pool before starting the server. This example needs `DB_HOST`, `DB_USER`, `DB_PASSWORD`, `DB_NAME` and `DB_CA`; `DB_PORT` defaults to 5432. See [DB.md](../DB.md) for queries and models.

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

## Tests

Run from the Kiln checkout. Use `./test-spinel.sh test/server_test.rb` for one file or `ci/run.sh` for the full CI checks.

```sh
bin/setup
SPINEL_WORKERS=1 ./test-spinel.sh
ci/db-offline.sh
```

## Updating Spinel

Change `ci/spinel-ref`, run `bin/setup`, then `ci/toolchain-test.sh` and the tests.
