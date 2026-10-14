# Changelog

## 0.0.3

A per-request memory leak, a crash on Linux when a streaming client hangs up,
two changes to what `Headers` and `HttpDate` hand out, and fixes to lanes
deadline handling and event-loop wake-ups.

### Lanes: a late job answered with its untouched response

When a lane took a job whose deadline had already passed, it built a 504
context with `fallback_context` but queued the original job, so the client got
the handler's untouched response (an empty 200) instead of `504 deadline
exceeded`. The lane now queues the 504 context. `test/event_lanes_test.rb`
sends 20 requests to a lane with a 1 µs `request_timeout` and expects 504 for
all of them; the check fails without the fix.

### Lanes: wake the event thread only when it sleeps

A lane woke the event thread twice per request: once after taking the job, so
the deadline watchdog could recompute its timeout, and once after finishing.
`wake_pump` is now kept for control paths (start, shutdown) and lanes and
streams call `nudge_pump`, which wakes the event thread only if it is parked,
and for a new job only if the job's deadline is earlier than the time the
thread will wake by itself (at most 0.25 s ahead). Before parking, the event
thread records that it is parked under `@wake_lock` and checks the done and
ready queues again, so a job finished in between is never left waiting.
Streams use the same parked-state check. The event loop parks immediately
when there is no work, without active spinning.

### Memory leak from `String#freeze`

Spinel makes a frozen heap String immortal: `sp_str_freeze_val` pins it in its
slab (`sp_slab_pin`), and `GC.start` does not free it. Measured on Linux:
49 bytes kept for every `freeze` of a short String, 33 bytes for every header
written through `Headers#[]=` or `#add`, which froze a copy of the name, the
key and the value. `Static` froze its `ETag` and `Last-Modified` on every
response, and the `Date` cache froze a new String once a second. Under load
RSS grew by 30 to 83 bytes per request and never came back (38 MB to 806 MB
across one regression run), and every collection swept the pinned Strings,
so GC sweeping took 11% of busy CPU on the first feature of a run and 61% by
the fifth. Nothing on the request path calls `freeze` now; RSS growth per
request is about 0.

### `Headers` contract

- A frozen name is stored as it is, a common name as the table's frozen String,
  and any other name as a copy; nothing is interned. `each` yields a copy of
  each name, so changing it cannot rename the stored header, and the caller's
  own String is not frozen. Names never leave `Headers` otherwise, so
  `append_to` writes them without checking them again.
- Values are no longer frozen. `[]=` and `add` still store a copy of an
  unfrozen value, so changing the caller's String later does not change the
  header, and a frozen value is stored as it is. The copy that `[]` and `each`
  return can be changed, and the change is sent. Before, it raised
  `FrozenError`.
- A value is checked for control bytes when it is stored, as before. `[]` and
  `each` hand out the stored value, so `append_to` checks an unfrozen value
  again and drops the header if it now carries CR or LF.
- Lookups use a table from common names to their lowercase keys and call
  `downcase` only for other names, so a lookup or write of a common name
  allocates nothing for the key.

`test/units_test.rb` checks that two passes of `each` yield different name
objects. Changing a yielded name and checking the wire is not enough on its
own: with Spinel's default String semantics the change does not reach the
stored String, so that check passed even when `each` yielded the stored name.

`append_to` appends to the String it is given and its return value is not
used. Spinel `9922a2c` refuses the other shape, `out = headers.append_to(out)`:
"a String a method returns as its parameter is mutated in place ... Mutate and
read the String through the variable passed in". The 0.0.2 row saying that
`<<` on a String argument does not change the caller's String did not
reproduce in a minimal case, `Stream.sse`'s old `field` helper included; what
triggered it there is not known.

Rechecking each name with `token?` and each key against the hop-by-hop list at
serialisation cost about 300 ns per response with four headers
(`Kiln::Response.build_wire` with `Content-Type`, `Vary`, `X-Request-Id` and a
frozen `X-Frame-Options`: 3.6-4.1 µs against 3.2-3.8 µs over six runs), and
copying frozen names added an allocation per such header; both are gone. On
`/text` of the regression server, which sends two headers, the difference is
within noise: 12.68 and 13.14 µs of CPU per request before, 12.62 and 12.72
after, alternating builds.

### `HttpDate.value`

`HttpDate.value` returns a copy of the cached `Date` value, which the caller
may change. `build_head` appends the cache itself through `HttpDate.append`.
Before, `value` returned the cached String. With Spinel's default String
semantics a change to it made a copy and did not reach the cache, but under
`--share-strings` it did: a reproduction of the old module wrote an injected
line into the next `Date` header. The new module keeps the cache private in
both modes.

### SIGPIPE on Linux

A client that closed its connection during a stream ended the whole process
with SIGPIPE (exit 141) on the event backend: libuv writes with `write`, and
only macOS sets `SO_NOSIGPIPE` on the socket. `kiln_uv_listen` now ignores
SIGPIPE, as Rust's standard library does at startup, so the write fails with
`EPIPE` and the stream ends with `Kiln::ClientGone`. The base backend already
sent with `MSG_NOSIGNAL`. Ignoring SIGPIPE is process-wide.

### Smaller changes

- `Kiln::Gzip.once` takes a deflate state from a pool of up to 4 per level and
  compresses into a per-thread scratch buffer (released above 1 MiB), then
  copies the result into a GC String of its exact size.
- `kiln_json_generate` starts its buffer at the size of the previous result on
  that thread (up to 1 MiB).
- `Stream#write` no longer scans each write with `ascii_only?`: Spinel appends
  any String to a binary buffer byte for byte.
- `Compress` writes `Vary`, `Content-Encoding` and `Accept-Ranges` through
  frozen constants.

On Linux x86-64 with Spinel `9922a2c`, inline mode, two rounds alternating the
old and new builds under `wrk -c25`: `/text` 73.4k-74.3k against 78.6k-81.4k
requests/s, `/json` 41.5k-45.9k against 43.2k-49.0k, `/gzip` 35.1k-37.5k
against 40.6k-44.9k. Allocations per request: `/text` 23.2 to 21.2, `/gzip`
31.2 to 26.2.

### Compression

`Kiln::Compress.new(app, level: 2, stream_level: 1, min_size: 1024)` is a
middleware after actix's `Compress` and Go's `gzhttp`. It gzips a response
when its `Content-Type` is `text/*`, `application/json`, `javascript`, `xml`,
`xhtml+xml`, `wasm`, any `+json` or `+xml` type, or `image/svg+xml`; its body
is at least `min_size` bytes (1 KiB, gzhttp's default), or it is a stream; and
`Accept-Encoding` allows gzip. `Accept-Encoding` is read with q-values:
`gzip;q=0` refuses it, `x-gzip` counts as gzip, and `*` allows it unless gzip
is listed. A qvalue outside 0..1 is ignored, and only that one preference is
dropped. A response that could be compressed gets `Vary: Accept-Encoding`
whether or not this client accepts gzip. A compressed response gets
`Content-Encoding: gzip`, a strong `ETag` becomes weak, and `Accept-Ranges`
is removed. For `GET` and `HEAD`, `If-Match` is checked again against that weak
validator, so a tag that matched the uncompressed bytes is a 412, while `*`
still passes. Other conditional methods retain the identity representation;
their handlers must evaluate the precondition before doing work. A 304
for a response this layer would compress carries that `Vary` and weak `ETag`
and drops `Accept-Ranges`; it does not carry `Content-Encoding`. A 304 for a
small or incompressible representation is unchanged. The body is compressed
before those fields are written, so a body that raises does not leave the
500 marked as gzip. Status 204, 205 and 206, responses with a
`Content-Encoding` or `Content-Range`, and any `Cache-Control: no-transform`
field are left alone.

A stream is compressed on the fly at `stream_level`. Its `out` wraps the
stream's writer: writes go through deflate, and `out.flush`, `out.event` and
`out.comment` do a `Z_SYNC_FLUSH` and flush the writer, so each SSE event
reaches the client when it is sent. A stream with `length:` loses the length,
since compressing changes it, and goes out chunked.

`ext/kiln_gzip.c` binds zlib-ng's native API (`zng_*`) with Spinel
`native_func`s that return GC Strings: `Kiln::Gzip.once` for a whole body, and
a handle for streams, closed in `ensure`. Errors raise `Kiln::CompressError`.

### Choosing the deflate library

AGENTS.md asks for the fastest library with evidence, on Linux and ARM. Four
were measured with the same harness (gzip, one core, Linux x86-64): a 686 KB
JSON document, a 177 KB HTML page, a 1.7 KB JSON object, and an SSE event of
120 bytes followed by `Z_SYNC_FLUSH`.

| Library | Level | JSON MB/s | ratio | HTML MB/s | SSE flush |
|---|---|---|---|---|---|
| system zlib 1.3 | 1 / 2 / 6 | 180 / 162 / 78 | .164 / .158 / .131 | 155 / 140 / 32 | 1148 ns |
| zlib-ng, SIMD | 1 / 2 / 6 | 490 / 331 / 139 | .211 / .151 / .129 | 465 / 315 / 46 | 87 ns |
| zlib-ng, generic C | 1 / 2 | 375 / 238 | .211 / .151 | 359 / 231 | 224 ns |
| libdeflate | 1 / 2 / 6 | 321 / 224 / 142 | .150 / .140 / .118 | 335 / 241 / 94 | no streaming |
| miniz | 1 / 6 | 151 / 48 | .174 / .131 | 139 / 21 | 2240 ns |

libdeflate matches zlib-ng at the same ratio but cannot stream, and kiln needs
`Z_SYNC_FLUSH` for SSE; miniz is the slowest; system zlib is about 1.5 times
slower than generic zlib-ng and 2 times slower than its SIMD build. zlib-ng is
vendored in `ext/zlib-ng` (zlib license) as its generic C build, which is
portable to Linux, macOS and ARM by construction: the SIMD build is faster
again but relies on per-architecture dispatch that could not be checked on ARM
here. Only compression is vendored; the six files from `arch/generic` sit in
the root as `generic_*.c` so their includes resolve, and `ext/zngsrc` holds one
wrapper per file with the defines `configure` would pass. The native API keeps
zlib-ng's symbols apart from a system libz that Spinel's own `zlib` package may
link into the same program.

Level 1 is zlib-ng's `deflate_quick`: 40% larger output than level 2. Level 2
is the default for bodies. A 120-byte event compresses to 9 bytes at every
level, while its flush costs 224 ns at level 1 and 1678 ns at level 2, so
streams default to level 1.

End to end (`bench/compress_server.rb`, event backend, `wrk -c20`, one core):
the 686 KB document goes out as 106 KB, 3.0 ms of CPU per request against
0.1 ms uncompressed, nearly all of it deflate; the 1.7 KB object goes out as
523 bytes, 28 µs against 8 µs. Reusing a compressor per thread with
`zng_deflateReset` saved about 5% on the small object and was left out: it
keeps some 280 KB per thread and level, and the base backend runs a thread per
connection.

### Server

An event handler running on a worker thread (`handlers: N`) that blocks past
`request_timeout` is answered 504, and the worker is replaced. Inline handlers
(`handlers: 0`) cannot be preempted without interrupting the event loop; use
worker threads when a strict deadline matters. Once `Server::Base` shutdown
has begun, a connection that has not yet been registered is not handed to the
handler; the client gets 503. Base sockets are set to nonblocking mode when
accepted. This bounds `sendmsg` on Darwin even when `MSG_DONTWAIT` is ignored:
the write waits in `IO.select` until the peer reads or `write_timeout`
expires.

## 0.0.2

Trie router, `Server#run`, background tasks, CORS and default headers, a
handler test helper, JSON, forms, query strings, and cookies, response
streaming and Server-Sent Events, static files with conditional requests and
byte ranges, and a fix for the event loop descriptor being closed when an
earlier server was collected.

### Static files

`Kiln::Static.new(root, param: "path", index: "index.html", max_age: nil,
dotfiles: false)` is a handler that serves the file named by the route
parameter `param` (a `*path` glob) under `root`. The root is opened once and
each request resolves a path inside it. File components are opened relative to
the root descriptor without following symlinks after resolution, so replacing
a path while a request runs cannot redirect the read outside the root. The
router refuses `.`, `..`, an encoded `/`, and a NUL in a glob. Names starting
with `.` answer 404 unless `dotfiles: true`, including symlinks to hidden
names. A directory serves its `index`, if any; there are no listings.

`Content-Type` comes from a table of common extensions (text types carry
`charset=utf-8`), else `application/octet-stream`. Every answer carries
`Last-Modified`, `ETag` (device, inode, change time, modification time, and
size),
`Accept-Ranges: bytes`, and `Cache-Control: public, max-age=N` when `max_age`
is set. Files of 256 KiB or less are read in one call; larger ones, and every
`HEAD`, go out as a stream of 64 KiB reads with their `Content-Length`.

### Conditional requests and ranges

`Kiln::Conditional.precondition(req, etag, modified)` returns 200, 304 or 412
in the order of RFC 9110 section 13.2.2, as Go's `checkPreconditions` does:
`If-Match` (strong comparison) or else `If-Unmodified-Since`, then
`If-None-Match` (weak comparison; 304 for `GET` and `HEAD`, 412 otherwise) or
else `If-Modified-Since`. `Kiln::Conditional.window(req, etag, modified,
size)` returns `[from, length, status]` for a `Range` header: one range of the
`bytes` unit (`a-b`, `a-`, `-n`), clamped to the file, 206; a range that
starts past the end, or `-0`, 416 with `Content-Range: bytes */size`. A
reversed range, several ranges, another unit, or an `If-Range` that does not
match the current ETag or date exactly, gets the whole file, as RFC 9110
allows. A 304 drops `Content-Type`.

`Kiln::HttpDate.parse` reads the three HTTP date formats (IMF-fixdate, RFC 850
with its two-digit year, asctime), as Go's `http.ParseTime` does, and returns
epoch seconds or nil. `Time.utc` turns 31 February into 3 March, so a parsed
date that does not come back unchanged is refused. An invalid date in a
request header is ignored, as RFC 9110 says.

### Streams with a length

`ctx.res.stream(length: n)` sends `Content-Length: n` and no chunked framing,
so the connection stays open afterwards on HTTP/1.1 and HTTP/1.0 alike. The
writer counts bytes: writing past `n` raises `ArgumentError`; a block that
ends short closes the connection after what it wrote, so the client sees a
truncated body rather than a complete one. `Response.stream_framing` makes the
chunked and keep-alive decision for both backends.

Measured with `bench/static_server.rb` (Spinel `9922a2c`, Linux x86-64, one
core, before the descriptor-based path checks). A 64 MiB file: event backend 164–180 MB/s against 192–219 MB/s for the
same bytes from memory; base backend 462–763 against 1693–2078 MB/s. A 1 KiB
file under `wrk -c20`: 26.2k requests/s on the event backend against 65.4k
from memory, 22.1k against 40.1k on base. Without the network,
`Kiln::Static#call` takes 17–22 µs for that file: `File.realpath` 1.3–1.6 µs,
`File.stat` 0.7, open and read 3.6, `httpdate` 1.0, and four header writes
2.8–3.7 µs. Reading request headers straight from `req.headers`, one `stat`
instead of two, and a dotfile check without `split` took it from 20.3 µs; the
rest reflects the earlier path-opening implementation.

### Streaming

`ctx.res.stream(status: 200, type: nil) { |out| ... }` and
`ctx.res.sse(status: 200) { |out| ... }` give the response a body that is
produced while it is written, as actix's streaming bodies and Rack 3 streaming
bodies are. The handler returns first: `request_timeout` limits the handler,
and the block runs in the write phase, with no request deadline, where
`write_timeout` limits each write. An SSE connection can stay open for as long
as it keeps writing.

`out.write(data)` (also `out << data`) buffers up to 16 KiB, as Go's
`bufio.Writer` behind `ResponseWriter` does; a write of 16 KiB or more is sent
as it is, after whatever was buffered, without being copied. `out.flush` sends
the buffer. `out.event(data, event:, id:, retry_ms:)` writes one SSE event and
flushes: each line of `data` gets its own `data:` field, and a line break in
`event` or `id` raises `ArgumentError`. `out.comment(text)` writes an SSE
comment, the usual keep-alive. `out.closed?` turns true once the client has
gone or the server has begun shutting down, so a loop can end on its own. A
write after the client has gone raises `Kiln::ClientGone`; an exception from
the block is logged and the connection is closed without the final chunk, so
the client can tell the body is incomplete.

Without a `length`, HTTP/1.1 responses use `Transfer-Encoding: chunked` and
no `Content-Length`. Each chunk head carries the CRLF that ends the previous
chunk, so a chunk is two pieces (head and data) and the data is never copied
into a frame. HTTP/1.0 responses are delimited by closing the connection.
`HEAD` gets the head only.
`res.sse` sets `Content-Type: text/event-stream; charset=utf-8`,
`Cache-Control: no-cache` and `X-Accel-Buffering: no` (which turns off nginx
buffering).

On the base backend the block runs on the connection's thread, after queued
pipelined responses are written. Each piece goes out with `sendmsg`. Darwin
may block in `sendmsg` once the send buffer is full despite `MSG_DONTWAIT`, so
`write_timeout` and `shutdown` cannot interrupt that call; Linux returns from
it when the buffer is full.

On the event backend the block runs on its own thread and hands the bytes to
the loop thread, which alone calls libuv. Two exports were added to
`ext/kiln_uv.c`: `kiln_uv_part` appends bytes to a connection's output without
finishing the request, and `kiln_uv_backlog` reports the bytes not yet taken
by the socket: those buffered plus those in `uv_write` requests, now counted
per connection. The end of the stream is the final chunk sent through
`kiln_uv_send`, which finishes the request as before. A writer that is more
than 256 KiB ahead of the socket waits, up to `write_timeout`, then gets
`Kiln::ClientGone`, so a client that does not read cannot make the server
buffer without bound. Responses to requests pipelined behind a stream on the
same connection are held until the stream ends and then sent in order. Once a
second, the loop checks that every open stream's connection still exists, so
a quiet SSE stream learns that its client has gone. A stream counts in
`in_flight`, so `shutdown` waits for it within `grace`.

`Kiln::Testing.call` runs a stream's block into a buffer, so `res.body` holds
what the client would receive, without chunk framing.

Measured with `bench/stream_server.rb` (Spinel `9922a2c`, Linux x86-64, one
core, three `curl` downloads of 64 MiB each, 64 KiB writes): the event backend
streams at 172–199 MB/s against 168–174 MB/s for the same 64 MiB as an
ordinary body; the base backend at 820–906 MB/s against 1048–1380 MB/s, one
`writev` per 64 KiB piece. A first version that copied each write into the
buffer and then into a frame streamed at 71–108 and 250–324 MB/s. `/health`
under `wrk -c50`, alternating builds over three rounds: 44.8–53.5k requests/s
and 11.1–13.5 µs CPU per request before, 50.8–53.6k and 11.2–11.8 µs after.

### Event backend: loop descriptor

Every event server in a process runs on libuv's default loop and wrapped its
epoll descriptor in a new `IO.for_fd`. When an earlier server was garbage
collected, that `IO` closed the shared descriptor, and the next server aborted
in `uv__io_poll` (`Assertion errno == EINTR failed`). Reproduced by starting
and stopping one server, calling `GC.start`, and starting another. The
descriptor is now wrapped with `autoclose: false`. `event_server_test` checks
it.

### Server#run

`server.run(grace:, signals: %w[INT TERM], tasks: nil)` starts the server,
blocks until one of `signals` arrives, logs it, and shuts down: first the
server with `grace`, then `tasks` (a `Kiln::Tasks`) with whatever is left of
it. It returns what `shutdown` returns. This matters on Spinel: a program that
has started a thread and set no `trap` is ended by SIGTERM at once, with no
`ensure`, so a server stopped by systemd or Kubernetes never drains without
it. The traps write one byte to a pipe and the main thread does the shutdown,
as Go's `signal.NotifyContext` plus `Server.Shutdown` does. Each signal's
previous handler is saved and restored, including when `start` raises. A
signal that had no handler is restored to `DEFAULT` before shutdown, so a
second Ctrl-C ends the process at once. `server.start` and
`server.shutdown(grace:)` remain for callers that manage signals themselves.

### Event backend

`write_timeout` (default 10 seconds) is accepted, as on the base backend. A
connection that still has response bytes in flight is closed once that long
has passed since the write was submitted. The sweep runs once a second, or
at the smaller of `read_timeout` and `write_timeout` when that is shorter, so
a sub-second timeout can fire. A client half-close, and a read error after a
request was parsed, does not discard that request. Each connection queues at
most 16 requests; further bytes stay in its read buffer until a response is
sent.

Names and values kept by `Kiln::Headers` are frozen. An unfrozen string passed
in is copied first, so the caller's string stays mutable and appending to the
string `headers['Name']` returns cannot add a line to the response.

### Router

Routes live in a tree of path segments. A request walks it by segment, and
when several routes match, the one registered first wins. The walk skips any
branch whose earliest route is later than the best match found so far. Among
routes for the same path, the request method is part of the match: with
`GET /users/new` and `POST /users/:id`, a `POST /users/new` reaches the second.
`HEAD` falls back to `GET`. A path that matches only under other methods
answers 405 with `Allow`.

`seal!` precomputes the winner of every static path for every method, so a
sealed router answers those with one hash lookup even when it also has
parameter routes. On 50 routes and a mixed request set (Spinel `9922a2c`,
Linux x86-64), routing took 1.6–2.0 µs per request before, 1.4–1.6 µs unsealed
and 1.0–1.1 µs sealed.

`*name` as the last segment takes the rest of the path, at least one segment:
`/files/*path` gives `params["path"] == "a/b.txt"` for `/files/a/b.txt`. Each
segment is percent-decoded, and a tail with a `.` or `..` segment or an
encoded `/` does not match, so the value is safe to join to a directory.

Registering the same method and path shape twice raises `ArgumentError`, as
does `*name` anywhere but last or an empty parameter name.

`trailing_slash: :strict` (the default) answers `/docs/` with 404 when only
`/docs` exists. `:redirect` sends 301 for `GET` and `HEAD` and 308 otherwise,
to the path without the slash, keeping the query, the way httprouter does. A
path with a backslash is never redirected. `not_found` and
`method_not_allowed` replace the plain-text answers. The 405 handler sees
`Allow` already set. `scope(prefix, wrap:)` and `namespace` wrap every handler
registered inside them, at registration, outer scopes outermost, so a wrap
costs nothing per request.

### Background tasks

`Kiln::Tasks` follows tokio-util's `TaskTracker` and `CancellationToken`.
Each task receives the group's `Kiln::Token`. `token.wait(seconds)` sleeps
until the deadline or until cancellation and says which. `every` runs a block
at a fixed rate and skips the ticks it missed while the block ran, as Go's
`time.Ticker` drops them, instead of firing a burst. A `StandardError` from a
task is logged with its name. In `every` the next tick still runs.
`shutdown(grace:)` refuses new tasks, cancels the token, waits up to `grace`,
kills what is still running, waits up to one more second for those threads to
stop, and returns how many it killed. Finished tasks are removed, so `size`
is the number still running.

`Kiln.pop(queue)` is `Queue#pop` bounded by the request deadline. It raises
`Kiln::DeadlineExceeded` (a 504 from the server) when the deadline passes
first. Like `Queue#pop(timeout:)` it cannot tell a pushed `nil` from a timeout
before the deadline, so do not push `nil`.

### Middleware

`Kiln::DefaultHeaders.new(app, headers)` adds each header the handler did not
set, as actix's `DefaultHeaders` does.

`Kiln::Cors` follows Go's `rs/cors`. A preflight (`OPTIONS` with `Origin` and
`Access-Control-Request-Method`) is answered 204 without calling the handler.
It gets the grant headers only when the origin, the method, and every
requested header are allowed, and it always sets `Vary`. Other requests with
an allowed `Origin` get `Access-Control-Allow-Origin` with that origin,
credentials, and exposed headers. `origins: ["*"]` allows any origin and
answers `*`. Combining it with `credentials: true` raises, as the Fetch
standard forbids it. `GET`, `HEAD`, and `POST` are always allowed methods.

### Testing handlers

`Kiln::Testing` calls a handler without a socket, like Go's `httptest` and
actix's `test::call_service`. It sets the request deadline the way a server
does (`timeout:`, 2 seconds by default), passes `state:` as `ctx.app`, and
turns `BadRequest`, `UnsupportedMediaType`, `DeadlineExceeded`, and
`PoolTimeout` into the responses a client would get. Any other exception
reaches the test.

### Request data and JSON

`ctx.req.json` parses the body once and memoizes it. The request must carry
`Content-Type: application/json` or an `application/*+json` type. A charset
other than UTF-8 is refused. `ctx.req.form` decodes an
`application/x-www-form-urlencoded` body and `ctx.req.query_params` decodes
the query string, both with `+` as a space and percent-escapes. A malformed
escape is kept as written, the last value of a repeated key wins, and `a[]=`
is an ordinary key. `ctx.req.cookies` parses the `Cookie` header. The first
value of a repeated name wins. These map to responses through the same path
as deadlines, in both backends:

| Raised | Response |
|---|---|
| `Kiln::BadRequest` (malformed JSON body, or a form or query that is not UTF-8) | 400, the message as the body |
| `Kiln::UnsupportedMediaType` (wrong `Content-Type` for `json` or `form`) | 415 |
| `Kiln::JsonError` from `Kiln::Json.parse` called directly | 500 |
| `Kiln::JsonGenerateError` | 500 |

A `Kiln::JsonError` raised outside `Request#json` is a server error on
purpose: a handler that parses a broken upstream response should not blame
the client.

`Kiln::Json.parse(text, max_nesting: 100)` and `Kiln::Json.generate(value)`
are backed by [yyjson](https://github.com/ibireme/yyjson) 0.13.0, vendored in
`ext/yyjson` (MIT, `ext/yyjson/LICENSE`) and compiled through
`ext/kiln_yyjson.c` with the incremental reader and the utilities disabled.
The binding is a Spinel `native_func`: C builds the Ruby values directly
through `spinel/runtime.h`, so `ext/build.sh` needs the Spinel headers. It
finds them next to the `SPINEL` (or `spinel`) binary the same way `spin` does.
Set `SPINEL_HDR_DIR` to override.

Parsing is strict RFC 8259: no comments, trailing commas, `NaN`, BOM, invalid
UTF-8, or lone surrogates. Integers past int64 become Bignums, `1e400` becomes
`Infinity`, `\u0000` is kept, a duplicate key keeps the last value, and object
keys are frozen Strings shared within one document. Nesting deeper than
`max_nesting` raises (100 levels pass, 101 do not, as in CRuby).

`generate` writes Hash, Array, String, Symbol, Integer (including Bignum),
Float, `true`, `false`, and `nil`. Hash keys may be Strings, Symbols, or
Integers, including Integers past int64. Anything else, invalid UTF-8, `NaN`,
`Infinity`, and nesting past 100 (a circular structure) raise
`Kiln::JsonGenerateError` instead of writing
`#to_s`. Floats are the shortest form that reads back exactly, in yyjson's
notation: `1e20` is written `100000000000000000000.0` and `1e22` as `1e22`,
where CRuby writes `1.0e+20`. `res.json(string)` still takes a prebuilt
string. `res.json_value(value)` serializes.

`set_cookie(name, value, path: "/", domain: nil, max_age: nil, secure: false,
http_only: true, same_site: "Lax")` validates the name as a token and the
value as cookie octets and raises `ArgumentError` otherwise, which also keeps
CR/LF out of the header. `SameSite=None` requires `secure: true`.
`delete_cookie(name)` sends `Max-Age=0`.

Against Spinel's bundled `json` (Spinel `9922a2c`, Linux x86-64, one core):
parsing a 686 KB document is 1.8–2.2x faster and a 147-byte object 1.3–1.4x.
Generating them is 18–22x and 7–8x faster. About 80% of parse time is
allocating the Ruby objects. yyjson itself reads the 686 KB document in about
1 ms.

### Limits

Kiln does not compress responses. Use a proxy for that.

### Spinel

| Behaviour | Workaround | Guarded by |
|---|---|---|
| A constant named `JSON` in any module is taken as the bundled json library and fails the build without `require "json"` | `Media::JSON_TYPE` | build |
| An empty `[]` assigned to an ivar or local and filled with Strings elsewhere can be typed `Array[Integer]` (`cannot store String into an Array[Integer]` at run time) | `[GET].drop(1)` | `units_test` |
| A frozen String constant pushed into an Array the caller passed in fails the build ("a String a method stores into an Array ... its caller passed it") | a literal at that site | build |
| A handler kept in an ivar of a plain class takes one inferred type; a `Handler` object called through it ran as a `Proc` and crashed (`sp_proc_call` into garbage) | `Router::Route` stays a `Struct`, whose fields are polymorphic | `server_test` |
| `headers['X'] = value` in `Cors#actual` made type inference for the whole program stop converging; the same call elsewhere did not | `delete` then `add` | build warning check |
| A mutable String inside a container reaches native code as `SP_BUILTIN_STRBUF` (an `sp_String *`), not `SP_TAG_STR` | `kiln_json.c` reads its `data` and `len` | `json_test` |
| A `Method` object is bound by name across classes: `Outlet#update(left)` took the calls a controller made through `method(:update)`, which then failed with `wrong argument type Kiln::Context (expected Integer)` | `Outlet` methods have names no handler is likely to use | `units_test` |
| `<<` on a String argument inside the called method does not change the caller's String | the helper returns the String and the caller appends it | `stream_test` |
| An empty `[]` that later holds objects can be typed `Array[Integer]`, and `[x].drop(1)` needs an `x` | the Array is created with its first element | `units_test` |

## 0.0.1

HTTP/1.1 runtime: router, request deadlines, structured task contexts, and
resource and CPU pools. HTTP/1.0 and HTTP/1.1 only. No TLS, HTTP/2, or
response streaming. `CpuPool#run` limits the caller's wait but cannot stop a
task already running in native code.

`resources` maps action procedures to conventional routes: `index`, `show`,
`create`, `update` (PUT and PATCH), and `destroy`. `namespace` adds a path
prefix. Nested namespaces compose. `seal!` freezes the route table.

### Resource pool

The pool creates resources on demand. `validate` and `max_lifetime` control
reuse. A resource is discarded when the `discard` callback matches an error
raised by the block. Otherwise it returns to the pool and the error is raised
to the caller. Set `close` to close discarded or expired resources.

If `close` fails, the default `on_close_failure: :quarantine` keeps that slot
counted against the pool size. This preserves the physical resource limit when
it is unknown whether the resource actually closed. The slot is unavailable
until you verify that the resource is gone and call `pool.release_quarantined`
(or pass a count to release only that many slots). If the application can
accept the risk of reusing capacity while a failed close may have left a live
resource, set `on_close_failure: :release`. That restores the slot immediately.

### CPU tasks

The queue is bounded. A task that expires before starting is rejected. A
timeout does not cancel work that has already started.

### Pipelined requests

When the read buffer already holds the complete head of the next request, the
response is queued in a per-connection outbox and the batch is written with
one `write_all` call (one or more `send` system calls). A batch holds at most
16 responses and 64 KiB. A full outbox is written before the current response
is considered, so neither limit is exceeded. Both limits are kiln's own. For
comparison: actix caps the queue of pipelined requests at 16
(`MAX_PIPELINED_MESSAGES`), and hyper's dispatcher loops at most 16 times per
poll so that one connection does not starve other tasks. Neither is a limit
on batched responses.

Queued responses are written before any other write on the socket: a parse
error, `100 Continue`, a late-handler 504, a large body, and before the
connection waits for more input. If that write fails, the connection is closed
instead of continuing with later requests. When the reaper or `shutdown` tears
a connection down, queued responses and the 504 are sent with a single
non-blocking write on a best-effort basis. A partial write is not retried.

Pipelined `/health` with 16 requests per batch: 40–48k to 79k requests/s,
16.4–19.3 to 11.5–11.6 µs CPU per request.

### Client disconnect

`ctx.client_gone?` (and `Kiln.client_gone?` / `Kiln.check_client!`, which
raises `Kiln::ClientGone`) reports that the peer has closed its sending
direction or the connection has failed. On systems that define `POLLRDHUP`,
it uses `poll` to see the close even when unread bytes are still queued. On
other systems it peeks one byte with `MSG_PEEK | MSG_DONTWAIT`. There it
reports `false` while unread bytes are queued. A client that only half-closes
its side still counts as gone, the same choice Go's `net/http` makes with its
background read. There is no thread per request: one system call per check.
Subtasks of `ctx.all` and `ctx.first` inherit the connection. CPU pool tasks
do not.

`Kiln::ClientGone` raised by a handler is not an error: no response is
written, the connection is closed, and nothing is logged. `Kiln::Rescue`
passes it on.

### Shutdown

`shutdown(grace:)` stops accepting, waits up to `grace` for requests that are
being handled or written, then stops the rest. Handlers still running are
killed. Responses still being written get `SHUT_RDWR` so the writer fails and
exits. Idle connections get `SHUT_RD`. The return value is the number of
requests (handled or being written) that had not finished when `grace` ran
out.

### Request path

Three server mutex acquisitions per request: registration, the switch to
writing, and the return to idle. Status lines, header prefixes, and
`Content-Length` values up to 4096 are prebuilt. The `Date` value is rebuilt
once per second from `CLOCK_REALTIME` seconds. Callgrind, 3000 sequential
keep-alive requests, raw numbers in `/tmp/kiln-validation/callgrind.txt`.

Multiple acceptors with `SO_REUSEPORT` are not offered. The Spinel runtime has
the C helper, but no Ruby API exposes it and `TCPServer.for_fd` is not
supported.

### Server backends

`Kiln::Server` is the public interface. It selects the event backend by
default. Pass `backend: :base` for the thread-per-connection engine. Both
backends provide `start`, `port`, `shutdown`, `connections`, `in_flight`,
`killed`, `late`, `free_slots`, and `handling`. Event `handling` counts
requests awaiting responses. `killed` and `late` are zero because the event
backend does not forcibly kill handlers.

The event backend uses the same router, `Request`, `Response`, and `Context`.
libuv owns the sockets in C: it accepts, reads, finds request boundaries
(pipelining included), scans headers with the same picohttpparser code, and
queues finished requests. One Ruby thread runs the loop, dispatches each
request, and hands responses back. Responses for one connection are written
with one `uv_try_write` per pass. There is no thread per connection and no
`epoll_ctl` per read.

`handlers: 0` (default) runs handlers inside the loop: fastest, but a handler
that waits (`Pool#with`, `ctx.sleep`, `CpuPool#run`, `ctx.all`) stops every
connection. `handlers: N` runs handlers on N threads. A connection is pinned
to thread `slot % N`, so pipelined responses keep their order, and a waiting
handler only delays connections that share its thread.

Nothing has to be installed. libuv 1.48.0 is vendored in `ext/libuv` (MIT,
`ext/libuv/LICENSE`, `ext/libuv/LICENSE-extra`) and compiled as part of the
package, the same way picohttpparser is. `spin build` and `ext/build.sh` build
it with the rest of kiln, and the program links it statically (no `libuv.so`
at run time). Each libuv source is compiled through a wrapper in `ext/uvsrc/`
that selects the platform: Linux files (epoll) under `__linux__`, macOS files
(kqueue, FSEvents loaded at run time) under `__APPLE__`, the defines libuv's
CMake build would pass set in `ext/uvsrc/uv_defines.h`. On other systems the
wrappers compile to nothing. The vendored libuv files keep their license
comments, like picohttpparser. Kiln's own wrappers have none.

On macOS libuv uses kqueue instead of epoll. `ext/kiln_uv.c` only calls the
libuv API, so the event code is the same. The Ruby loop sleeps in `IO.select`
on `uv_backend_fd`, which libuv supports for kqueue as well as epoll. The full
Spinel suite, including both event backend tests, passes on macOS with one and
two workers.

Protocol and lifecycle, as tested in `test/event_server_test.rb` and
`test/event_lanes_test.rb`:

- A request with `Connection: close` (or HTTP/1.0 without `keep-alive`) is the
  last one parsed on its connection. Later pipelined bytes are discarded and
  their handlers never run.
- `Expect: 100-continue` gets `100 Continue` once the body has not arrived yet
  and every earlier response on the connection has been queued. Any other
  `Expect` value gets 417.
- The request deadline is set for the handler, so `Kiln.deadline`,
  `Kiln.check!`, and `Kiln.pause` see it in both modes. Deadlines are
  cooperative: a handler is not killed at its deadline.
- `shutdown(grace:)` stops accepting and reading new requests. Complete
  requests already parsed and their responses are allowed to finish. Idle
  connections and incomplete requests are closed. After `grace`, unfinished
  handlers are stopped and queued requests are discarded. The method returns
  the number of requests that did not finish.
- One event server per process: the C side keeps one libuv loop. A second
  `start` raises.

During shutdown the last response on each connection carries
`Connection: close`, so the client does not send another request into a
connection the server is about to close. `shutdown` returns in bounded time
even when a handler is stuck in a long C call or the loop thread has died. In
that case the loop keeps ownership of libuv until every handler worker exits,
then stops it. The shutdown caller returns without waiting indefinitely, and a
loop-thread exception is logged rather than raised.

Not supported by the event backend: chunked request bodies (501),
absolute-form targets, `OPTIONS *`, `client_gone?`. Use
`Kiln::Server.new(..., backend: :base)` where these matter. The base backend
also supports custom `write_timeout`, `kill_grace`, `coop_budget`, and
`shards`. The event backend rejects non-default values for these options
rather than silently ignoring them.

`shards: N` splits the base backend's per-request bookkeeping (the lock, the
deadline heap, and the counters) into N independent groups, and new
connections are assigned to them in turn. Set it to the number of Spinel
workers, the same way the benches derive `handlers:` from the core count.
`bench/body_modes.rb` and `bench/hello_modes.rb` pass `KILN_CPUS`, or
`SPINEL_WORKERS` when that is unset. Recorded on macOS with an 11 KB body and
`wrk -t1 -c50`, the median went from 25.4k to 35.8k requests/s with four
shards on four workers and from 29.3k to 34.0k with three on three. On two
workers it made no difference. The default is one shard.

One CPU shared with `wrk -t1 -c50`, hello world, Spinel `9922a2c`, CPU per
request: base backend 27.1–29.2 µs, event inline 11.5–11.8 µs, event with 4
handler threads 14.2–15.0 µs. These recorded figures are historical.
`bench/event_compare.sh` reproduces the comparison and writes its output under
`/tmp/kiln-validation/` (`SPINEL=… ROUNDS=3 CONNS=50 bench/event_compare.sh`,
needs `wrk`).

### Spinel

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
