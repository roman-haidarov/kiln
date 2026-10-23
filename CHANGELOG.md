# Changelog

## 0.0.9

### Changed

- The HTTP parser keeps the header-block offset it has already scanned and continues from there.
- MySQL and MariaDB connections keep a prepared-statement cache (`statement_cache:` on `Conn.open`, default 32).
- PostgreSQL connections prepare a named statement on the second run of the same text and keep up to `statement_cache:` of them.
- Query results are read from the driver in batches of up to 256 rows with one registry lock per call, and every driver call takes the registry lock twice instead of three times.

## 0.0.8

### Added

- Kiln::DB (experimental) for PostgreSQL through libpq 17+ and for MySQL and
  MariaDB through MariaDB Connector/C 3.4+: connections, a per-thread connection
  pool, models, relations, transactions with savepoints, and bulk import. See
  [DB.md](DB.md).
- Kiln::DB is opt-in: `spin build` and `ext/build.sh` build Kiln without it and
  need no database headers. `KILN_DB=1 ./ext/build.sh` builds it.

### Changed

- The code passes RuboCop with the project configuration. Large classes are split
  into nested modules; methods with long parameter lists take small value objects.
- Breaking: `Runtime::CpuPool#await_workers` is now `wait_stopped?`.
  `Runtime::CpuPool#shutdown`, `Runtime::Pool#shutdown` and `DB::Pool#close` return
  the number of workers or resources still running (`0` on a clean stop) instead
  of `true`/`false`.
- Breaking: `HTTP::Request.new(verb, target, headers, body, wire)` takes an
  `HTTP::Request::Wire` (version, payload, ALPN) instead of keywords.
  `Transport::Listen.new(kind, tls)` is configured with `use_tcp`, `use_unix` or
  `use_fd`; the `tcp`, `unix`, `fd` and `parse` factories are unchanged.
  `HTTP::Cookies.serialize` takes an `HTTP::Cookies::Cookie`.
- Kiln::DB: `Col#null` (with `is_null` as an alias), `Model.one_to_many` (with
  `has_many` as an alias). The low-level `DB::Native.connect_params` takes a
  `DB::Endpoint`; `bind_str`, `bind_bytes`, `block_import` and `block_text` take
  grouped arguments.
- Fixed `DB::ExactDecimal#<=>` for values whose digit strings differ in length.
- The event backend marks inline handlers so that Kiln::DB can refuse to block
  the event loop.
- Breaking: the code is grouped into namespaces, one file per class under
  `kiln/<namespace>/`. `Kiln::Server`, `Kiln::Static` and `Kiln::Testing` keep
  their names; everything else moved:

  | Namespace | Was `Kiln::…` |
  | --- | --- |
  | `Kiln::Routing` | `Router`, `Context`, `Controller` |
  | `Kiln::HTTP` | `Request`, `Response`, `Headers`, `Json`, `Media`, `Form`, `Cookies`, `Payload`, `Stream`, `WebSocket`, `Conditional`, `PathSyntax`, `ReadBuffer`, `BadRequest`, `UnsupportedMediaType`, `PayloadTooLarge`, `RequestTimeout`, `TrailersTooLarge`, `JsonError`, `JsonGenerateError`; `HttpDate`, `HttpSyntax`, `HttpNative` are now `HTTP::Date`, `HTTP::Syntax`, `HTTP::Native` |
  | `Kiln::Middleware` | `Compress`, `Cors`, `DefaultHeaders`, `RequestId`, `AccessLog`, `Rescue`, `CompressError` |
  | `Kiln::Runtime` | `Pool`, `CpuPool`, `Tasks`, `Token`, `Supervisor`, `DeadlineExceeded`, `PoolTimeout`, `WorkerLost`, `ClientGone`; `Kiln.now`, `Kiln.pause`, `Kiln.pop`, `Kiln.check!` and the other deadline helpers are now `Kiln::Runtime.*` |
  | `Kiln::Transport` | `Listen`, `Tls`, `Sock` |
  | `Kiln::Observability` | `Log` |

## 0.0.7

### Changed

- JSON generation uses the vendored yyjson writer.
- Vendored zlib-ng includes its x86-64 and arm64 SIMD code, selected at run time.
- Pinned picohttpparser to v1.4 and added an SSE4.2 build selected at run time on x86-64.
- The base backend decodes chunked bodies with the shared C decoder.
- Oversized chunk sizes are answered with 413 on both backends.
- Added `-DKILN_GENERIC` to build portable C only.

### Fixed

- Fixed `Payload#read(0)` on chunked bodies to return an empty string.
- Made concurrent TLS context failures and error messages thread-safe.
- Reject gzip and libuv buffers that exceed their supported length limits.
- Keep failed gzip streams owned by their caller until close; destroy instead of pooling them.
- Exercise TLS successful context lifecycles and compare generic/SSE4.2 Pico parsers in native CI.
- Restore out-of-the-box `spin build` using portable native headers and generic fallbacks without trusted native build scripts; `ext/build.sh` retains SIMD compilation and runtime dispatch.
- Reject writes after a finished gzip stream without repeatedly allocating output buffers, and reset finished state when a pooled compressor is reused.
- Instrument the SSE4.2 parser in libFuzzer and add an end-to-end `spin new`/`spin add`/`spin build` CI smoke test.

## 0.0.6

### Added

- Added streamed request bodies, including chunked transfer encoding.
- Added HTTP upgrades, connection hijacking and WebSocket support.
- Added TLS with ALPN configuration and optional client certificates.
- Added TCP, Unix socket and inherited-descriptor listeners, with configurable backlog and TCP_NODELAY.
- Added separate header, keep-alive, body-read and client-disconnect timeouts.
- Added per-route and per-scope request body limits.
- Updated vendored libuv to 1.53.0.

### Fixed

- Fixed delayed event-loop wakeups for new connections and resumed reads or writes.
- Fixed SIGPIPE termination when writing to disconnected clients.
- Fixed streamed request failures so later reads preserve the original error.
- Fixed handler deadlines and shutdown handling for streamed requests.
- Fixed WebSocket invalid UTF-8 close reasons to use close code 1007.
- Fixed TLS test retries to reuse the original write buffer.
- Fixed base-backend header timeout accounting and removed unreachable buffered chunked-body code.

## 0.0.5

### Added

- Added native C static analysis, parser fuzzing, coverage reporting and focused ThreadSanitizer checks.
- Extracted event request framing into a separately testable C parser.
- Added differential checks comparing the event parser with its previous implementation.

### Fixed

- Rejected invalid parser arguments and guarded request-length calculations against overflow.

## 0.0.4

### Added

- Added controller classes with request-scoped context, request, response and route parameters.
- Added router modules that configure routes and connect them to controller actions.

## 0.0.3

### Added

- Added response compression for eligible bodies and streams.
- Added pooled gzip state and per-thread compression buffers.

### Fixed

- Fixed a per-request memory leak caused by freezing strings on the request path.
- Fixed event-loop wakeups, late lane responses and client disconnect handling.
- Made `Headers` values safe to copy and mutate without changing stored headers.
- Made `HttpDate.value` return a copy of its cached value.
- Fixed WebSocket close errors for invalid UTF-8 reasons.
- Reduced repeated request-path work when no streamed uploads are active.

## 0.0.2

### Added

- Added a trie-based router with path parameters, wildcard paths, scopes, route wrappers and configurable not-found and method-not-allowed handlers.
- Added `Server#run` for signal-aware graceful shutdown.
- Added background task groups with cancellation and bounded shutdown.
- Added CORS, default response headers and a socket-free handler test client.
- Added JSON parsing and generation, form and query parsing, and cookie helpers.
- Added response streaming and Server-Sent Events.
- Added static file serving with conditional requests, ETags and byte ranges.
- Added length-delimited streaming responses.

### Fixed

- Prevented collection of an earlier server from closing the shared event-loop descriptor.
- Preserved keep-alive framing for streams with a declared content length.

## 0.0.1

### Added

- Added the HTTP/1.0 and HTTP/1.1 server, router, request deadlines and structured task contexts.
- Added resource and CPU pools.
- Added conventional resource routes and nested namespaces.
- Added bounded HTTP request pipelining and ordered response writes.
- Added client-disconnect checks and graceful shutdown.
- Added event and base server backends behind `Kiln::Server`.
