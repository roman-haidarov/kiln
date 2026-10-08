# kiln

Minimal HTTP/1.1 runtime for Spinel. It provides a router, request deadlines,
structured task contexts, and resource and CPU task pools.

## Install

Add the local checkout to a Spinel project:

```sh
spin add kiln --path ../kiln
```

Build the project with `spin build`. The native HTTP parser is built from
`ext/` using the C compiler configured in your environment.

## Run a server

```ruby
require "kiln"

router = Kiln::Router.new
  .get("/", ->(ctx) { ctx.res.text("Hello, world!\n") })
  .namespace("/api") { |api| api.configure(Api::Users) }
  .seal!

log = Kiln::Log.new($stdout)
app = Kiln::Rescue.new(router, log)
server = Kiln::Server.new(app, nil, log: log, host: "127.0.0.1", port: 8080)
server.start
begin
  loop { Kiln.pause(3600) }
ensure
  server.shutdown(grace: 5.0)
  log.close
end
```

Handlers receive a context. Read the request with `ctx.req` and write a response
with `ctx.res`. `ctx.sleep`, `ctx.all`, `ctx.first`, and `Kiln.pause` cooperate
with the request deadline. `server.start` runs in the background; keep the main
thread alive and call `server.shutdown` to stop accepting requests and allow
active requests up to the grace period to finish. The example shuts down when
the main loop exits or is interrupted.

Put each API area in its own module and file. A module's `configure` method
receives the router. `namespace` adds a path prefix, and nested namespaces
compose:

```ruby
module Api
  module Users
    class << self
      def configure(router)
        router.resources("/users", { index: method(:index), show: method(:show) })
      end

      def index(ctx)
        ctx.res.text("Users")
      end

      def show(ctx)
        id = ctx.req.params["id"]
        ctx.res.text("User #{id}")
      end
    end
  end
end
```

`resources` maps the supplied action procedures to conventional HTTP routes.
It supports `index`, `show`, `create`, `update` (PUT and PATCH), and `destroy`.
Pass only the actions the module implements. Direct procedures remain available
for custom routes, for example
`router.get("/health", ->(ctx) { ctx.res.text("ok") })`.

## Resource pool

```ruby
pool = Kiln::Pool.new(4) { connect_to_service }

result = pool.with(timeout: 1.0) do |connection|
  connection.query("SELECT 1")
end
```

The pool creates resources on demand. `validate` and `max_lifetime` control
reuse. A resource is discarded when the `discard` callback matches an error
raised by the block; otherwise it returns to the pool and the error is raised
to the caller. Set `close` to close discarded or expired resources.

If `close` fails, the default `on_close_failure: :quarantine` keeps that slot
counted against the pool size. This preserves the physical resource limit when
it is unknown whether the resource actually closed. The slot is unavailable
until you verify that the resource is gone and call `pool.release_quarantined`
(or pass a count to release only that many slots). If the application can
accept the risk of reusing capacity while a failed close may have left a live
resource, set `on_close_failure: :release`; this restores the slot immediately.

## CPU tasks

```ruby
cpu = Kiln::CpuPool.new(2, queue: 16)
value = cpu.run(timeout: 0.5) { expensive_calculation }
cpu.shutdown(grace: 1.0)
```

The queue is bounded. A task that expires before starting is rejected. A
timeout does not cancel work that has already started.

## Tests

Run the suite with Spinel:

```sh
./test-spinel.sh
```

Set `SPINEL=/path/to/spinel` if the compiler is not on `PATH`. Do not use
`spin test --regen`; it generates snapshots with CRuby. See
[VALIDATION.md](VALIDATION.md) for the recorded checks and their limitations.

The suite is checked with Spinel using `SPINEL_WORKERS=1` and `2`. Test output
is written to `/tmp/kiln-validation/tests/`; set `KILN_VALIDATION_DIR` to
change the location.

## Pipelined requests

When the read buffer already holds the complete head of the next request,
the response is queued in a per-connection outbox and the batch is written
with one `write_all` call (one or more `send` system calls). A batch holds at
most 16 responses and 64 KiB; a full outbox is written before the current
response is considered, so neither limit is exceeded. Both limits are kiln's
own. For comparison: actix caps the queue of pipelined *requests* at 16
(`MAX_PIPELINED_MESSAGES`), and hyper's dispatcher loops at most 16 times per
poll so that one connection does not starve other tasks; neither is a limit on
batched responses.

Queued responses are written before any other write on the socket: a parse
error, `100 Continue`, a late-handler 504, a large body, and before the
connection waits for more input. If that write fails, the connection is closed
instead of continuing with later requests. When the reaper or `shutdown`
tears a connection down, queued responses and the 504 are sent with a single
non-blocking write on a best-effort basis; a partial write is not retried.

Pipelined `/health` with 16 requests per batch: 40–48k → 79k requests/s,
16.4–19.3 → 11.5–11.6 µs CPU per request.

## Client disconnect

`ctx.client_gone?` (and `Kiln.client_gone?` / `Kiln.check_client!`, which raises
`Kiln::ClientGone`) reports that the peer has closed its sending direction or
the connection has failed. On systems that define `POLLRDHUP`, it uses `poll`
to see the close even when unread bytes are still queued. On other systems it
peeks one byte with `MSG_PEEK | MSG_DONTWAIT`; there it reports `false` while unread
bytes are queued. A client that only half-closes its side still counts as
gone, the same choice Go's `net/http` makes with its background read. There is
no thread per request: one system call per check. Subtasks of `ctx.all` /
`ctx.first` inherit the connection; CPU pool tasks do not.

`Kiln::ClientGone` raised by a handler is not an error: no response is written,
the connection is closed, and nothing is logged. `Kiln::Rescue` passes it on.

## Shutdown

`shutdown(grace:)` stops accepting, waits up to `grace` for requests that are
being handled or written, then stops the rest: handlers still running are
killed, responses still being written get `SHUT_RDWR` so the writer fails and
exits, idle connections get `SHUT_RD`. The return value is the number of
requests (handled or being written) that had not finished when `grace` ran out.

## Request path cost

Three server mutex acquisitions per request: registration, the switch to
writing, and the return to idle. Status lines, header prefixes and
`Content-Length` values up to 4096 are prebuilt; the `Date` value is rebuilt
once per second from `CLOCK_REALTIME` seconds. Callgrind, 3000 sequential
keep-alive requests, raw numbers in `/tmp/kiln-validation/callgrind.txt`.

Multiple acceptors with `SO_REUSEPORT` are not offered: the Spinel runtime has
the C helper, but no Ruby API exposes it and `TCPServer.for_fd` is not
supported.

## Server backends

`Kiln::Server` is the public interface. It selects the event backend by
default; pass `backend: :base` to use the original thread-per-connection
engine. Both internal backends provide `start`, `port`, `shutdown`,
`connections`, `in_flight`, `killed`,
`late`, `free_slots`, and `handling`. Event `handling` counts requests awaiting
responses; `killed` and `late` are zero because the event backend does not
forcibly kill handlers.

The event backend uses the same router, `Request`, `Response` and `Context`.
libuv owns the sockets in C: it accepts,
reads, finds request boundaries (pipelining included), scans headers with the
same picohttpparser code and queues finished requests. One Ruby thread runs the
loop, dispatches each request and hands responses back; responses for one
connection are written with one `uv_try_write` per pass. There is no thread per
connection and no `epoll_ctl` per read.

```ruby
require "kiln"

server = Kiln::Server.new(router, state, log: log, port: 8080, handlers: 4)
server.start
```

`handlers: 0` (default) runs handlers inside the loop: fastest, but a handler
that waits (`Pool#with`, `ctx.sleep`, `CpuPool#run`, `ctx.all`) stops every
connection. `handlers: N` runs handlers on N threads; a connection is pinned to
thread `slot % N`, so pipelined responses keep their order, and a waiting
handler only delays connections that share its thread.

Nothing has to be installed. libuv 1.48.0 is vendored in `ext/libuv` (MIT,
`ext/libuv/LICENSE`, `ext/libuv/LICENSE-extra`) and compiled as part of the
package, the same way picohttpparser is: `spin build` and `ext/build.sh` build it
with the rest of kiln, and the program links it statically (no `libuv.so` at
run time). Each libuv source is compiled through a wrapper in `ext/uvsrc/` that
selects the platform: Linux files (epoll) under `__linux__`, macOS files
(kqueue, FSEvents loaded at run time) under `__APPLE__`, the defines libuv's
CMake build would pass set in `ext/uvsrc/uv_defines.h`. On other systems the
wrappers compile to nothing. The vendored libuv files keep their license
comments, like picohttpparser; kiln's own wrappers have none.

On macOS libuv uses kqueue instead of epoll; `ext/kiln_uv.c` only calls the
libuv API, so the event code is the same. The Ruby loop sleeps in `IO.select`
on `uv_backend_fd`, which libuv supports for kqueue as well as epoll. The full
Spinel suite, including both event backend tests, passes on macOS with one and two
workers.

Protocol and lifecycle, as tested in `test/event_server_test.rb` and
`test/event_lanes_test.rb`:

* A request with `Connection: close` (or HTTP/1.0 without `keep-alive`) is the
  last one parsed on its connection; later pipelined bytes are discarded and
  their handlers never run.
* `Expect: 100-continue` gets `100 Continue` once the body has not arrived yet
  and every earlier response on the connection has been queued; any other
  `Expect` value gets 417.
* The request deadline is set for the handler, so `Kiln.deadline`,
  `Kiln.check!` and `Kiln.pause` see it in both modes. Deadlines are
  cooperative: a handler is not killed at its deadline.
* `shutdown(grace:)` stops accepting and reading new requests. Complete
  requests already parsed and their responses are allowed to finish; idle
  connections and incomplete requests are closed. After `grace`, unfinished
  handlers are stopped and queued requests are discarded. The method returns
  the number of requests that did not finish.
* One event server per process: the C side keeps one libuv loop; a second
  `start` raises.

During shutdown the last response on each connection carries
`Connection: close`, so the client does not send another request into a
connection the server is about to close. `shutdown` returns in bounded time
even when a handler is stuck in a long C call or the loop thread has died; in
that case the loop keeps ownership of libuv until every handler worker exits,
then stops it. The shutdown caller returns without waiting indefinitely, and a
loop-thread exception is logged rather than raised.

Not yet supported by the event backend: chunked request bodies (501),
absolute-form targets, `OPTIONS *`, `client_gone?`. Use `Kiln::Server.new(...,
backend: :base)` where these matter. The base backend also supports custom
`write_timeout`, `kill_grace`, `coop_budget`, and `shards`; the event backend
rejects non-default values for these options rather than silently ignoring them.

`shards: N` splits the base backend's per-request bookkeeping (the lock, the
deadline heap, and the counters) into N independent groups, and new
connections are assigned to them in turn. Set it to the number of Spinel
workers, the same way the benches derive `handlers:` from the core count:
`bench/body_modes.rb` and `bench/hello_modes.rb` pass `KILN_CPUS`, or
`SPINEL_WORKERS` when that is unset. Recorded on macOS with an 11 KB body and
`wrk -t1 -c50`, the median went from 25.4k to 35.8k requests/s with four
shards on four workers and from 29.3k to 34.0k with three on three; on two
workers it made no difference. The default is one shard.

One CPU shared with `wrk -t1 -c50`, hello world, Spinel `9922a2c`, CPU per
request: base backend 27.1–29.2 µs, event inline 11.5–11.8 µs,
event with 4 handler threads 14.2–15.0 µs. These recorded figures are
historical; `bench/event_compare.sh` reproduces the comparison and writes its
output under `/tmp/kiln-validation/` (`SPINEL=… ROUNDS=3 CONNS=50
bench/event_compare.sh`, needs `wrk`).

## Limits

Kiln supports HTTP/1.0 and HTTP/1.1. It does not provide TLS, HTTP/2, or response
streaming; use a proxy for those features. `CpuPool#run` limits the caller's
wait but cannot stop a task already running in native code.

## Spinel quirks the code relies on

Spinel-specific behavior covered by the test suite:

| Behaviour | Workaround | Guarded by |
|---|---|---|
| A call from `Pool#with` to another method can be lost in one of its specializations (`NameError` at run time) | explicit receiver: `self.drain_returns` | server test: pool wait bounded by deadline -> 504 |
| `thread.join(timeout)` inside a method named `join` ignored the timeout | `CpuPool#await_workers`; servers poll `alive?` | shutdown tests |
| `Hash#delete` / `Queue#pop` return "value or nil"; arithmetic with it makes counters polymorphic and breaks C compilation | `fetch(key, 0).to_i`, `pop.to_i` | build |
| A top-level variable assigned values of different types breaks dispatch (`started.pop(timeout: 1)` became `Array#pop`) | distinct names in tests | `units_test` build |
| Setters of new `Struct` fields and some `attr_accessor` setters were not found at run time | `Outbox` uses explicit methods, no setters | server tests |
| A `Struct` field is polymorphic; passing a String to a method called through it copies the String | `Outbox` is passed as a typed argument; `fits?` takes a size | callgrind instruction count |
| String literals allocate on every evaluation (no `frozen_string_literal`, comments are not allowed) | evaluate a literal comparison once | allocation count |
| `SizedQueue#push(obj, timeout:)` returned the queue instead of `nil` on timeout | non-blocking push first, deadline re-checked | full CPU queue test |
| `Mutex#synchronize` inside an `each` block in a method with early `return` failed to compile (`_retv declared void`) | loop body moved to its own method | build |
