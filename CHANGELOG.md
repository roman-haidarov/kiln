# Changelog

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
