# Validation

Kiln tests and benchmarks must run with Spinel. Do not use CRuby or MRI. Test
output and benchmark artifacts are written to `/tmp/kiln-validation/` by
default; set `KILN_VALIDATION_DIR` to choose another directory.

## Test suite

Run all test files with:

```sh
SPINEL_WORKERS=1 ./test-spinel.sh
SPINEL_WORKERS=2 ./test-spinel.sh
```

The test runner compiles each test with Spinel, compares its output against the
checked-in snapshot, and stores raw output under
`$KILN_VALIDATION_DIR/tests/`. Set `SPINEL` to the Spinel compiler path when it
is not on `PATH`. `TEST_TIMEOUT` controls the per-test timeout in seconds.

Tests cover HTTP parsing and framing, routing, response ordering, request and
CPU deadlines, pool ownership and close failures, client disconnect handling,
server shutdown, and worker lifecycle. The mutation runner checks that selected
regressions are detected:

```sh
SPINEL_WORKERS=1 python3 bench/mutations.py
```

## HTTP parser checks

`bench/differential.mjs` compares the parser with llhttp WASM over generated
inputs and records complete counters and examples as JSON. The captured corpus
contained 100,056 cases across two seeds, with no unexplained acceptance or
request-boundary mismatch. `bench/native_fuzz.c` runs native parser cases under
ASan and UBSan; 100,000 cases completed without sanitizer errors. These checks
do not prove correctness for every possible input, and sanitizer runs do not
check for data races.

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

## Runtime limits

`Thread#kill` cannot interrupt a long native call until it returns to a
scheduling point. CPU task timeouts stop the caller's wait but do not cancel
work that has already started. Client disconnect detection uses `POLLRDHUP`
where available; the `MSG_PEEK` fallback cannot detect closure while unread
bytes remain queued.

The native parser is tested with differential and sanitizer checks. TSan was
not run. Load and performance figures describe the recorded machines and
workloads; they are not guarantees for other systems.

## References

- [RFC 9112](https://www.rfc-editor.org/rfc/rfc9112.html)
- [Go chunked decoder](https://go.dev/src/net/http/internal/chunked.go)
- [Go HTTP server](https://go.dev/src/net/http/server.go)
