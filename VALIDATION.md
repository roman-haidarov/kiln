# Validation

Kiln tests and benchmarks must run with Spinel. Do not use CRuby or MRI. Test
output and benchmark artifacts are written to `/tmp/kiln-validation/` by
default; set `KILN_VALIDATION_DIR` to choose another directory.

## Test suite

Current tree: 21 test files, 864 checks. The transport-related files are
`test/listen_test.rb`, `test/timeouts_test.rb`, `test/payload_test.rb`,
`test/websocket_test.rb`, `test/tls_test.rb` and `test/sigpipe_test.rb`.
`test/listen_test.rb` also checks invalid `reuse_port`, invalid `buffer_body`
and removal of `workers:`; `test/websocket_test.rb` checks heartbeat PONG
matching and the 1007 answer to a close reason that is not UTF-8;
`test/payload_test.rb` checks that a handler waiting on a stalled upload gets
504 on every backend and the server keeps serving. `test/tls_test.rb` uses the
`openssl` command line tool for the ALPN, TLS 1.2 and client certificate
checks. `test/sigpipe_test.rb` starts each backend in a child process with the
default `SIGPIPE` disposition and resets connections mid-response; on Linux it
passes with or without the SIGPIPE fix, so it guards the macOS behavior only.

### Review fixes (current source tree, 2026-10-19)

Linux x86-64, 2 vCPU, Spinel `9922a2c` built from source:

- `./test-spinel.sh`: 21/21 with `SPINEL_WORKERS=1` and 21/21 with
  `SPINEL_WORKERS=2`, twice each (before and after the last event-loop change).
- `ci/c-native.sh all` with `KILN_FUZZ_SECONDS=10`: Clang Static Analyzer on
  the six native modules, seed checks, all 10 libFuzzer targets, TSan harness.
- `clang-tidy` and `cppcheck` with the AGENTS.md settings on `ext/kiln_uv.c`
  and `ext/kiln_sock.c`: no new findings other than braces style already used
  across the file and `unusedFunction` on the new FFI exports. `lizard`: the
  two existing warnings (`kuv_parse`, `kuv_send_finish`), none new.
- RuboCop, Reek, Flog and Flay were not run: rubygems.org is not reachable
  from this environment. `ruby -c` passed on every changed Ruby file.
- First request on a new connection, `curl` against the event backend (inline
  and lanes): 251 ms before the `kiln_uv_settle` fix (0.0.5 and the 0.0.6
  candidate alike), 0.3-0.8 ms after. A 16 MiB response: 256 ms before, 5-8 ms
  after. The base backend was not affected.
- `wrk -t1 -c32`, lanes, server pinned to one core and `wrk` to the other,
  five alternating 5 s rounds, mean requests/s (this tree before the
  pump-loop change; the Callgrind counts in CHANGELOG cover the final tree):
  `/text` 0.0.5 74 327, candidate 71 249, this tree 76 208;
  `/json` 48 026, 46 553, 47 576; `/gzip-stream` (3 rounds) 22 397, 22 000,
  22 633. The spread between rounds of one build is up to 10 %, so these only
  show that this tree is not slower than 0.0.5 on this machine. Callgrind
  instruction counts per request are in the 0.0.6 CHANGELOG entry.
- Lanes `/gzip-stream` with `Accept-Encoding: gzip`, three consecutive `wrk`
  runs against one server with `SPINEL_WORKERS=1` and `2`: the server stayed
  up. The SIGPIPE crash reported on macOS did not reproduce on Linux before
  the fix either; the macOS run is still to be repeated.

Historical run summaries below record suite sizes at the time of those checks;
they do not describe the current test set.

Run all test files with:

```sh
SPINEL_WORKERS=1 ./test-spinel.sh
SPINEL_WORKERS=2 ./test-spinel.sh
```

The test runner compiles each test with Spinel, compares its output against the
checked-in snapshot, and stores raw output under
`$KILN_VALIDATION_DIR/tests/`. Set `SPINEL` to the Spinel compiler path when it
is not on `PATH`. `TEST_TIMEOUT` controls the per-test timeout in seconds.

The full eight-file suite passed 293 checks on macOS with Spinel `9922a2c` and
both `SPINEL_WORKERS=1` and `2`. MRI was not used. After JSON landed, the
ten-file suite (including `test/json_test.rb`) passed on macOS with that same
Spinel and both worker counts.

On Linux x86-64 with Spinel `9922a2c` built from source, the ten-file suite
(including `test/json_test.rb`, 75 checks) passes with `SPINEL_WORKERS=1` and
`2`. `json_test` also passes unchanged with `SPINEL_GC_STRESS=1`, which
collects on nearly every allocation and so exercises the GC roots in
`ext/kiln_json.c`.

The JSON binding was run with kiln's C compiled under ASan and UBSan
(`KILN_EXT_CFLAGS="-O1 -g -fsanitize=address,undefined"`, the program linked
with `--link -lasan --link -lubsan`): four threads each parsed and regenerated
a 686 KB document ten times and fed 20,000 randomly corrupted inputs to the
parser, with no report. Instrumenting the whole program is not possible: the
Spinel collector scans stacks conservatively and reads ASan's redzones, and
`__asan_handle_no_return` fails on Spinel's own stacks, which is why
`kiln_json.c` hides `noreturn` from the compiler in sanitizer builds only.

With the router tree, `Server#run`, `Kiln::Tasks`, `Kiln::Testing`, `Cors`
and `DefaultHeaders`, the eleven-file suite (including
`test/features_test.rb`, 60 checks) passes on Linux x86-64 with Spinel
`9922a2c` and `SPINEL_WORKERS=1` and `2`. The same eleven-file suite passed
on macOS with that Spinel and both worker counts. `features_test` and `json_test`
pass unchanged under `SPINEL_GC_STRESS=1`, and `features_test`, which sends
itself SIGTERM, passed 8 repeated runs alternating the worker count. The
router benchmark ran the old and new routers alternately, three rounds of
three runs each.

RuboCop 1.39 (Ubuntu's; `TargetRubyVersion: 3.2`, the newest it knows) over
`kiln kiln.rb test bench` reports 496 offenses against 516 before; the router
went from 4 `AbcSize` and 4 `PerceivedComplexity` findings to 3 and 1, with
`call` and `find` left whole because they are the hot path. New files add only
`FrozenStringLiteralComment` and `Documentation`, which would need comments.
Reek, flog, flay and rubyfast were not run: they install from rubygems.org,
which the sandbox could not reach. `kiln_json.c` is formatted with the repo
`.clang-format` (minus `BinPackLongBracedList`, unknown to clang-format 18),
cppcheck 2.13 (also exhaustive) reports nothing in it, and clang-tidy 18 reports
the categories `kiln_http.c` also has (braces, include-cleaner) plus GC-macro
`no-int-to-ptr`, the bounded recursion, and Annex K `memcpy_s`/`snprintf_s`.
The analyzer's null `memcpy` on an empty buffer was real and is fixed.

Tests cover HTTP parsing and framing, routing, response ordering, request and
CPU deadlines, pool ownership and close failures, client disconnect handling,
server shutdown, and worker lifecycle. The mutation runner checks that selected
regressions are detected:

```sh
SPINEL_WORKERS=1 ruby bench/mutations.rb
```

## HTTP parser checks

`bench/differential.rb` compares the parser with llhttp WASM over generated
inputs and records complete counters and examples as JSON. The captured corpus
contained 100,056 cases across two seeds, with no unexplained acceptance or
request-boundary mismatch. `bench/native_fuzz.rb` runs native parser cases under
ASan and UBSan; 100,000 cases completed without sanitizer errors. These checks
do not prove correctness for every possible input, and sanitizer runs do not
check for data races.

## Native C checks

CI runs Clang Static Analyzer on `kiln_http.c`, `kiln_uv.c` and
`kiln_uv_parse.c`. When the pinned Spinel headers are available, it also checks
`kiln_json.c` and `kiln_gzip.c`. `kiln_yyjson.c` only includes the vendored
yyjson implementation, so that translation unit and all vendored parser and
codec code are excluded.

The HTTP helper targets and the event request parser run under libFuzzer,
AddressSanitizer and UndefinedBehaviorSanitizer. Each target has its own seed
corpus and HTTP dictionary. The campaign runs for five seconds per target by
default, and the corpus is minimized with `-merge=1` after each target and
cached between CI runs. Set `KILN_FUZZ_SECONDS` to change the duration. Before
fuzzing, a seed check reads the seed files from the corpus directory and
requires successful parses, the expected helper results and the expected event
parser states and error statuses (400, 413, 417, 431, 501). The
event parser's seed corpus includes a header larger than its 16 KiB limit, and
its targets allow inputs up to 32 KiB plus one byte that selects `max_body`.
The `uv-parse-diff` target compares `kiln_uv_parse_request` with the 0.0.4
inline framing logic. Coverage output lists the selected parser and helper
functions only; it does not present whole-file coverage as parser coverage.
Coverage varies by Clang version and platform.

Recorded on Linux x86-64 (Ubuntu 24.04, clang 18.1.3), five seconds per target:
the static analyzer passed for `kiln_http.c`, `kiln_uv.c`, `kiln_uv_parse.c`,
`kiln_json.c` and `kiln_gzip.c` with the Spinel `9922a2c` headers; the seed
check and all nine targets passed from an empty corpus and again from the
minimized corpus; TSan passed. Every listed helper function and every
`kiln_uv_parse.c` function had full line coverage except
`kiln_uv_parse_request` (89%, its argument checks) and `kiln_http_scan_at`
(88%). A mutant that answered 413 at `body == max_body` was caught by
`uv-parse-diff` within 30 seconds, and a seed that no longer parsed failed the
seed check. A separate 60-second differential run of 1.3 million inputs found
no difference between the two implementations.

The native TSan harness checks concurrent calls against thread-local socket
receive buffers and status. It does not exercise libuv's event-loop-owned
queues or Spinel's green-thread scheduler, and it is not a whole-runtime race
check. Run the native checks with `ci/c-native.sh all` using Clang with
libFuzzer support and matching `llvm-profdata` and `llvm-cov` tools. Locally,
results go to `/tmp/kiln-c-native/` and the corpus to `/tmp/kiln-corpus/` by
default. CI uploads the reports as `kiln-ci-linux-amd64`,
`kiln-ci-linux-arm64` and `kiln-ci-macos-arm64` artifacts, under `c-native/`.
The macOS workflow installs Homebrew `lld` and uses it for sanitizer and
coverage-instrumented binaries because Apple's linker rejects relocations
emitted by recent LLVM versions in this configuration.

## Load and performance

The recorded load check used 10,000 idle clients for 10 seconds, then sent
requests during a mixed burst. With `SPINEL_WORKERS=1` and `2`, connections,
in-flight work, and pool allocations returned to their expected idle state
after disconnect and shutdown. The measured idle CPU use was 0.299% of one core.
The burst p99 values were 160.2 ms and 147.0 ms; they include client queuing
and are not a steady-state latency target.

Performance comparisons must use the Spinel binary and a captured profile or
benchmark. Available scripts include:

```sh
./bench/run.sh
./bench/profile_server.sh
./bench/matrix.sh BASE_SERVER NEW_SERVER
./bench/router_constants.sh array
```

`bench/run.sh` stores benchmark output, allocation reports, and summaries under
`$KILN_VALIDATION_DIR/bench/`. The profile script writes its gprofng data under
`$KILN_VALIDATION_DIR/`. The matrix and router scripts also write their results
there. Compiled binaries remain under the ignored `build/` directory.

On macOS Spinel, the recorded router collection benchmark measured frozen Hash
membership at about six times the throughput of frozen Array membership. The
Spinel `Set` implementation is array-backed and was slower for both membership
and sequential traversal. Router action lookup occurs during configuration, so
the application startup impact depends on the number of resource routes.

## Transport layer (0.0.6)

Recorded on Linux x86-64 (Ubuntu 24.04, 2 vCPUs, clang 18.1.3, OpenSSL 3.0.13)
with Spinel `9922a2c`:

- `ci/c-native.sh all` with `KILN_FUZZ_SECONDS=20`: the static analyzer passed
  for `kiln_http.c`, `kiln_uv.c`, `kiln_uv_parse.c`, `kiln_tls.c`,
  `kiln_sock.c`, `kiln_ws.c`, `kiln_json.c` and `kiln_gzip.c`; the seed check
  (including the new chunked, upgrade and oversized-but-streamed event seeds
  and three chunk decoder cases) and all ten libFuzzer targets passed from an
  empty corpus; TSan passed. `kiln_uv_chunk_decode` had full line coverage and
  `kuv_parse_headers` full line coverage.
- `clang-tidy` with the check set in `AGENTS.md` reports, for the new and
  changed C, only findings the existing files already carry (missing braces,
  the C11 Annex K `*_s` suggestions, include-cleaner, `_GNU_SOURCE`).
  `cppcheck --enable=all --inconclusive` reports the `uv_write` ownership
  hand-off as a leak (the request is freed in `kuv_after_write`, as before) and
  the FFI exports as unused. `lizard -C 15 -L 80 -a 8` flags `kuv_parse` (20)
  and `kuv_send_finish` (21) in `kiln_uv.c`, which were over the limit in
  0.0.5 (20 and 23), and nothing new.
- RuboCop, Reek, flog, flay and rubyfast were not run: the gem host was not
  reachable from the build machine. `ruby -wc` passes for every file under
  `kiln`, `test` and `bench` except the existing unused variable in
  `bench/mutations.rb`.
- `bench/regression.sh` with `wrk`, 16 connections, 5 s rounds, `FEATURES=text`,
  the 0.0.5 and 0.0.6 trees alternated three times on the same machine. Medians
  of the three rounds, requests per second:

  | run | inline 0.0.5 | inline 0.0.6 | lanes 0.0.5 | lanes 0.0.6 |
  | --- | ---: | ---: | ---: | ---: |
  | 1 | 68,961 | 68,141 | 48,580 | 48,063 |
  | 2 | 70,124 | 62,486 | 45,040 | 48,040 |
  | 3 | 67,501 | 66,629 | 50,216 | 45,687 |

  The medians differ by 3.5 % (inline) and 1 % (lanes), inside the spread of
  repeated runs of one tree (up to 9 %), so this run shows no regression it
  can resolve. Resident memory after the inline rounds was 12.1 MB before and
  12.4 MB after.
- The README examples for listeners, TLS, workers, request bodies and
  WebSocket were compiled and served `curl` requests, including an HTTP/2
  capable `curl --http2` that negotiated `http/1.1` through ALPN.

## Runtime limits

`Thread#kill` cannot interrupt a long native call until it returns to a
scheduling point. CPU task timeouts stop the caller's wait but do not cancel
work that has already started. Client disconnect detection uses `POLLRDHUP`
where available; the `MSG_PEEK` fallback cannot detect closure while unread
bytes remain queued.

The native parser is tested with differential, fuzzing, and sanitizer checks.
Load and performance figures describe the recorded machines and workloads;
they are not guarantees for other systems.

## References

- [RFC 9112](https://www.rfc-editor.org/rfc/rfc9112.html)
- [Go chunked decoder](https://go.dev/src/net/http/internal/chunked.go)
- [Go HTTP server](https://go.dev/src/net/http/server.go)


## libuv event server (EventServer)

Hypothesis checked: moving socket I/O into a C event loop removes most of the
per-request cost of `Server`. Same router and handler, Spinel `9922a2c`,
`SPINEL_WORKERS=1`, one CPU shared with `wrk -t1`, three rotated rounds.
These figures were recorded during the comparison; raw output is not stored in
the project. Rerun `bench/event_compare.sh` to write fresh results under
`/tmp/kiln-validation/`.

| connections | Server | EventServer inline | EventServer, 4 handler threads |
|---|---|---|---|
| 50, CPU per request | 27.1–29.2 µs | 11.5–11.8 µs | 14.2–15.0 µs |
| 50, requests/s | 24–26k | 53–55k | 46–49k |
| 50, p99 | 5.7–7.6 ms | 1.9–6.1 ms | 2.0–2.4 ms |
| 256, CPU per request | 30.8–31.1 µs | 13.6–13.8 µs | not measured |
| 256, requests/s | 22.7–23.0k | 44.3–45.3k | not measured |

Measured on a shared core; on separate cores absolute numbers differ, the CPU
per request is the comparable figure. Tests: `event_server_test.rb` (protocol:
pipelining, bodies, 400/404/500/501, close, shutdown) and
`event_lanes_test.rb` (a waiting handler does not block another connection,
pipelined order, shutdown), both with `SPINEL_WORKERS=1` and `2`; the full
suite passes 8/8 on Spinel `9922a2c` with two workers. The load measurements
were captured on Linux and have not been repeated on macOS.


## Self-contained build (vendored libuv)

Kiln vendors libuv 1.53.0 from upstream tag `v1.53.0` (commit
`840404ce8ba7cc0204be52389a6cfff9f2c90fb6`) under `ext/libuv/src` and
`ext/libuv/include`. `ext/build.sh` compiles the selected Linux and macOS
sources through wrappers in `ext/uvsrc/` with explicit include paths. The
event backend remains self-contained and links libuv statically. On macOS,
libuv's runtime probe selects `EVFILT_USER` for async wakeups when supported;
otherwise it retains its pipe fallback. Kiln's `kiln_uv_settle` watcher fix
now uses public `uv_backend_timeout()` instead of the private watcher queue.
The event pump caps `IO.select` by libuv's next deadline in addition to its
handler deadline. `ci/libuv-embedding.sh` compiles the vendored library into a
standalone native executable and tests wakeups, new HTTP connections, short
header timeouts and five start/stop cycles. On Darwin 24.6.0 ARM64, Apple clang
17.0.0 passed all five native embedding iterations. The full Spinel suite
passed 21/21 with `SPINEL_WORKERS=1` and again with `SPINEL_WORKERS=2` on
Spinel `2026.09.12+6969 (9922a2c74)`.

The 1.53.0 sources compile on macOS ARM64 with the pinned Spinel toolchain.
No A/B latency or CPU-per-request comparison of 1.48.0 and 1.53.0 in
`handlers: N` mode has been recorded, so no performance gain is claimed.


## EventServer

`EventServer` stops accepting and reading when shutdown begins. It completes
fully parsed requests and their responses, closes idle connections, and drops
incomplete requests. When `grace` expires, running handlers are stopped and
queued parsed requests are counted as unfinished. The pump owns all libuv loop
operations, including cleanup; `shutdown` waits for workers and the pump to
terminate before returning.

The C parser stops after `Connection: close`, including HTTP/1.0 requests that
also contain `keep-alive`. It answers `100 Continue` in order, returns 417 for
unsupported expectations, and closes connections on allocation failures. The
shutdown tests cover fully parsed pipelines in inline and threaded modes and
count active and queued requests when grace expires in both modes.

`ext/build.sh` keys cached objects by platform, compiler, flags, and SHA-256
digests of each C source and header path and content under `ext/`. The benchmark
script requires `wrk` and exits nonzero if a run completes no requests.

The EventServer load figures above were captured on Linux and have not been
remeasured on macOS.


## EventServer audit fixes

`shutdown` waits with limits only: for the grace period, up to 0.5 s for the
loop thread to stop dispatching (or until it is found dead), then a bounded
wait for handler and loop threads; an exception from a dead thread is logged,
not re-raised. The loop keeps ownership of libuv until all handler workers have
exited, even if the shutdown caller has already returned. The last response on
each connection during shutdown carries `Connection: close` in both modes (the
response head is now built on the loop thread, which asks the C side whether
the connection closes after it).
Requests taken after the grace cutoff are counted as unfinished, and
`kiln_uv_abort` sends finished responses before closing. `ext/build.sh` hashes
all sources with one `sha256sum` call (`shasum -a 256`, then `cksum` as
fallbacks): an unchanged build takes about 0.1 s instead of about 3 s.

New tests: shutdown with a dead loop thread returns in bounded time (the
previous unbounded wait hangs and is killed by the test timeout); only the last
pipelined response during shutdown says `Connection: close`; the inline
response finished during shutdown says `Connection: close`. Linux, Spinel
`9922a2c`, `SPINEL_WORKERS=1` and `2`, repeated runs.


## Pump stop race

Found while rechecking: when the grace period expired, `shutdown` could send
`Thread#kill` to the loop thread just as it entered its cleanup, before it set
`@pump_stopping`. The kill then aborted the cleanup, `kiln_uv_stop` never ran,
the listener stayed open and a new `EventServer` in the same process failed
with `EALREADY` (4 of 10 runs of the grace-cutoff scenario on Linux with one
worker). Fixed twice over: the loop thread is killed only while it runs an
inline handler (tracked under the same mutex), and libuv is stopped in a nested
`ensure`, so an interrupted wait for handler threads still stops it (late
wake-ups are already guarded by `@uv_closed`). Test: after a grace cutoff a new
server starts in the same process; 12 runs without failures, while a mutant
restoring the old kill condition fails 2 of 10. Starting a second server while
one runs now raises "another Kiln::EventServer is already running in this
process" instead of libuv's `EALREADY` text.

## Response head and body sent separately

Profiles of the 11 KB `bench/body_modes.rb` load on macOS showed that about a
fifth of server CPU went to joining the response head and body in Ruby:
`payload.ascii_only?` scanned the body byte by byte, `wire << payload` scanned
it again inside `sp_str_append_grow` before choosing the result encoding, and
then copied it into a grown buffer that `kiln_uv_send` copied once more. The
head and body now cross the FFI boundary as two `:str` arguments. In the event
backend `kiln_uv_send` reserves space once and copies both into the connection
buffer. In the base backend `kiln_sendv` writes both with one `sendmsg` and two
`iovec` entries, the way hyper writes a head and body together, so bodies over
16 KB no longer need a second system call and the `INLINE_BODY` branch is gone.
Only the pipelined outbox still joins strings. The generated C passes both
strings to the C functions as pointers without a copy.

Measured on Linux x86, one vCPU, Spinel `9922a2c`, `wrk -t1 -c20`, original and
new binaries alternating, 3 rounds of 8 s, server CPU per request from
`/proc/<pid>/stat`:

| load | mode | before, µs | after, µs |
|---|---|---|---|
| 11 KB body | inline | 44.2 | 35.0 |
| 11 KB body | lanes | 44.8 | 32.5 |
| 11 KB body | server | 51.6 | 37.7 |
| hello world | inline | 7.9 | 7.7 |
| hello world | lanes | 10.1 | 9.9 |
| hello world | server | 17.8 | 16.7 |

New over-the-wire checks send a non-ASCII body through both backends, a HEAD
response through the event backend, and two pipelined non-ASCII responses
through the base outbox.
The nine-file suite passed 301 checks on Linux with Spinel `9922a2c` and both
`SPINEL_WORKERS=1` and `2`.

## IPv6 listen and write hand-off in the event server

`kiln_uv_listen` accepted only IPv4 literals, because it parsed the host with
`uv_ip4_addr` alone, so `host: '::1'` failed in the event server while the base
server's `TCPServer` accepted it. The host is now parsed as IPv4 first and then
with `uv_ip6_addr`, and `kiln_uv_port` reads the port from `sockaddr_in6` when
the socket is IPv6. The check that serves a request over `::1` runs only when
the host has IPv6. The Linux machine used for this change had none, so there
the check passed without serving anything; it still needs a run on a host with
IPv6, such as macOS.

When `uv_try_write` left part of the output unsent, or a write was still
pending, `kiln_uv_flush` copied the rest of the connection buffer into a new
block for `uv_write`. It now hands the buffer itself to the write request: the
write starts at the first unsent byte, `kuv_after_write` frees the original
start of the block, and the connection gets a fresh buffer on its next
response. A failed `uv_write` now frees the block and closes the connection
instead of leaving the write count raised. Test: two pipelined 2 MB responses
arrive whole and in order; on Linux the first `uv_try_write` sent 3.9 MB and
left 80 KB, so the partial path runs, and a mutant that starts the write at the
beginning of the block instead of the first unsent byte fails it.

## Streaming

`test/stream_test.rb` (54 checks) runs every network case on the event
backend with `handlers: 0` and `handlers: 2` and on the base backend: chunked
framing decoded by the test, the SSE wire format, HTTP/1.0 and `HEAD`, a
response pipelined behind a stream arriving after its final chunk, a stream
outliving `request_timeout`, a client that closes, a client that never reads
(cut off through the 256 KiB limit and `write_timeout`), an error that ends the
connection without the final chunk, and `shutdown` ending an SSE loop through
`closed?`. On Linux x86-64 with Spinel `9922a2c` it passes under
`SPINEL_GC_STRESS=1` and in six runs alternating `SPINEL_WORKERS=1` and `2`,
and the twelve-file suite passes with both worker counts.

For `ext/kiln_uv.c`, clang-tidy 18 and cppcheck 2.13 (also exhaustive) report
nothing new against 0.0.2 except the house `braces-around-statements` style
and `unusedFunction` on the two new FFI exports. RuboCop 1.39
(`TargetRubyVersion: 3.2`) reports new `Metrics` findings only on per-stream
methods, and `Style/HashEachMethods` on `refresh_backlog`, whose loop deletes
from the Hash it walks, so it iterates a copy of the values. Reek, flog, flay
and rubyfast were not run here: they install from rubygems.org, which the
sandbox could not reach.

## Compression

`test/compress_test.rb` inflates every answer with Spinel's own
`zlib` package, a different DEFLATE implementation from the vendored zlib-ng.
It covers `Accept-Encoding` with q-values, the type and size rules, `Vary`,
the weakened `ETag`, untouched 204, 206 and 304 answers, `no-transform`, an
existing `Content-Encoding`, a sized stream that loses its length, SSE, and a
static file whose weak ETag still revalidates. On the event backend with
`handlers: 0` and `handlers: 2` and on the base backend, the first compressed
SSE event reaches the client while the stream is still open. It passes under
`SPINEL_GC_STRESS=1`. On Linux x86-64 with Spinel `9922a2c` the updated
fourteen-file suite passes with `SPINEL_WORKERS=2`; the compiled tests also
pass against their snapshots with `SPINEL_WORKERS=1`. The blocked-handler
deadline test uses `handlers: 2`: inline handlers on the event loop cannot
be preempted safely. The server lifecycle test passed twelve consecutive runs
at `SPINEL_WORKERS=2`, checking the shutdown and free-slot transition.

`ext/kiln_gzip.c` is clean under clang-tidy 18, cppcheck 2.13 (exhaustive) and
lizard, apart from `no-int-to-ptr` on the GC macros and `unusedFunction` on the
FFI exports. The vendored zlib-ng sources are not linted, like libuv. RuboCop
1.39 reports only `Metrics` on the test's router builder in the new files.
