# Changelog

## 0.0.18

- Add `KILN_WORKERS=N`: N application CPU workers, with no main-thread offset.
  Standard event handlers and lazy DB pools use 16 slots per CPU worker; Base
  shards follow the same worker budget. Explicit concurrency settings remain
  available. The managed runtime and build fingerprints include this change.
- Run independent libuv loops per application worker in the event backend,
  including inline mode. Loop state is owned explicitly, listeners are shared
  through duplicated descriptors, shutdown drains all loops together, and
  request IDs stay unique within the server. Connection generations remain
  unique across loop lifetimes, and stale stream notifications are ignored.
- Recover interrupted toolchain builds with OS file locks; validate inherited
  lock descriptors. Route macOS CI through the managed builder and key caches
  by the revision, patches and builder inputs.
- Add a repeatable scaling benchmark built through the Getting Started
  wrappers. It records CPU, p99, raw wrk output, errors and 1/2/4 worker runs.

### Fixed

- The public native DNS resolver uses 64-bit generation tokens for take and
  cancel. A stale token cannot consume or cancel a reused slot; cancellation
  checks the generation before connection ownership. Submit now requires a
  token output argument, including a zero token for numeric addresses.
  Native callers must rebuild against the updated header.
- Interrupted PostgreSQL DNS lookups belong to the connection and are cancelled
  by native connection close. Completed and pending requests no longer exhaust
  the resolver queue after `Thread#raise` or `Thread#kill`. Generation tokens
  reject stale results after slot reuse.
- Deadline expiry is checked before resuming a timed-out native wait, so TLS
  and query timeouts report `Kiln::DB::Timeout` without resuming an expired
  Connector/C operation.
- The Spinel descriptor wait bridge is built separately from the standalone
  database core, restoring native safety, sanitizer, affinity and DNS tests.
- macOS CI uses the same patched runtime builder and validates cached installs;
  local toolchain directories are excluded from Git and Docker contexts.
- Database connections reuse one socket wait wrapper and close it before the
  driver connection closes. Temporary DNS, connect and cancellation waits
  park the driver's own descriptor and drop that poller registration before
  returning, without a Ruby `IO`. This keeps the normal query path from
  accumulating registrations and avoids the Spinel 9d10403 `ensure` unwind
  crash on an early PostgreSQL stream `break`.
- `test/db/schema_guard_test.rb` required a MariaDB account without the
  `TRIGGER` privilege to see no row in `information_schema.triggers`. MariaDB
  11.4.13 returns the row and leaves `ACTION_STATEMENT` NULL. The test now
  requires that statement to stay hidden, and `returning: true` still raises
  `UnsupportedReturn` before any write.
- `bench/modes.rb` passes the requested lane count to the `lanes` handler
  pool instead of always using four handlers.
- The pinned Spinel build applies `patches/spinel/placement.patch`: newly
  created helpers participate in initial placement, and threads created by
  another thread also choose the least populated helper. Running threads
  retain their existing worker.

### Added

- A checksum-verified, project-local Connector/C build shared by setup,
  application wrappers, Docker and macOS CI. `ci/mariadb-ref` pins the tested
  upstream TLS implementation; headers and runtime older than 3.4.12 fail
  explicitly. Build caches include the client fingerprint and library path.
- Offline regressions for interrupted DNS, recycled resolver tokens and one
  stalled TLS handshake. `ci/run.sh` runs that offline suite with
  `SPINEL_WORKERS=1`. Descriptor interruption tests run in ordinary offline CI.
- `bin/setup`, `bin/spin` and `bin/spinel` automatically build and validate a
  project-local toolchain. `ci/spinel-ref` is the single pinned revision;
  `ci/build-spinel.sh` is shared by local builds, Docker and macOS CI.
- Build provenance and compiler/runtime checksums reject stale or damaged
  installations. macOS cache keys include the patch and build scripts.
  A patch application failure stops compilation.
- Application build caches record the managed toolchain fingerprint. On a
  change, `bin/spin` moves prior `build/bin` and `build/test` outputs into
  `build/.kiln-previous.*` before rebuilding, including binaries with newer
  timestamps. Other build artifacts are retained.
- Placement checks for threads created from main and from another thread,
  bootstrap failure/cache checks, and `test/db/wait_registration_test.rb`.

## 0.0.17

### Fixed

- MySQL: `import(..., on_duplicate_key_ignore: true)` raised `Kiln::DB::Unsupported: exec simple command returned rows` and broke the connection as soon as `INSERT IGNORE` reported a duplicate. The import reads the warnings with `SHOW WARNINGS`. MySQL 8.4 cannot prepare that statement (error 1295), so Kiln fell back to the text protocol, and the driver's text path rejected every result set. The failed prepare had also already replaced the `INSERT` warnings with its own 1295 error, so even a returned result would have been wrong. MariaDB prepares `SHOW WARNINGS`, so only MySQL failed. The check was added in 0.0.11; the live suite had not run against MySQL since then. This failed `gate_c_test` and `q_gates_test`.
  - `SHOW WARNINGS`, `SHOW ERRORS`, `SHOW COUNT(*) WARNINGS`, `SHOW COUNT(*) ERRORS` and `GET [CURRENT | STACKED] DIAGNOSTICS` now go to the text protocol without a prepare, so the diagnostics of the previous statement survive. Leading whitespace, `#`, `-- ` and `/* */` comments are skipped, and the keywords are matched without regard to case.
  - The MySQL/MariaDB text protocol returns result sets. It reads them with `mysql_store_result_start`/`_cont` and decodes them by column type, like prepared results. Other statements that have no bind values and that the server refuses to prepare (for example `CHECK TABLE` on MySQL) now return their rows instead of failing.
  - A text-protocol statement that produces more than one result set raises `Unsupported` and marks the connection broken, so the connection is not left out of sync. A text-protocol statement reports its own rows and warning count. It does not expose the result or warnings of the prepared statement that ran before it.
- `test/db/schema_guard_test.rb` created its limited MariaDB account for `'127.0.0.1'`. Under Docker Desktop the server sees the client at the bridge gateway (for example `172.26.0.1`), so that login was refused. The test now creates the account for the client host the server reports in `USER()`, and it connects through `DB_MARIA_HOST`.
- `test/db/stmt_cache_test.rb` and `test/db/stream_import_test.rb` did not compile on Spinel `9d10403`. For `e.class.name` on an exception rescued as `Kiln::DB::Error` or `Exception`, the compiler emits the nullable `const char *` from `sp_class_name_or_nil` into a boxed `sp_RbVal` slot. The C compiler then reports `incompatible types when assigning to type 'sp_RbVal' from type 'const char *'`, and inside string interpolation `invalid initializer`. The tests use `e.class.to_s` and `"#{e.class}"`, which print the same names. 0.0.16 worked around the same compiler defect in `number_test.rb`.
- `test/db/typed_decode_test.rb.expected` expected `Integer nil` for the signed 64-bit minimum (`int8` and `BIGINT` −9223372036854775808) on PostgreSQL, MySQL and MariaDB. That snapshot was recorded on Spinel `519280d`, which used the minimum as its nil sentinel, so `inspect` printed `nil`. DB.md maps integer columns to `Integer` and only `NULL` to `nil`, `Codec.typed_cell` returns the minimum, and Spinel `9d10403` keeps the two distinct (`int64_sentinel_test`, 0.0.16). The snapshot now expects `Integer -9223372036854775808`.

### Changed

- The MySQL/MariaDB driver also loads `mysql_store_result_start`, `mysql_store_result_cont`, `mysql_fetch_row`, `mysql_fetch_lengths` and `mysql_more_results` from Connector/C. All of them are present in the required 3.4 series. No FFI declaration in `kiln/db/native.rb` changed.

### Added

- `test/db/mysql_text_protocol_test.rb` is a live MySQL and MariaDB test. It covers `SHOW WARNINGS` (also in lower case and after a comment), `SHOW COUNT(*) WARNINGS`, `SHOW ERRORS`, `GET DIAGNOSTICS` and a streamed `SHOW WARNINGS` after `INSERT IGNORE`. It also checks that `import` with `on_duplicate_key_ignore` passes duplicates and still raises `import warnings` for a truncation, and that `CHECK TABLE` returns its rows through the fallback. Two more checks: a text statement without rows returns no rows from the previous result, and a diagnostic statement with bind values raises `Unsupported`. On 0.0.16 it fails at the first `SHOW WARNINGS` with `exec simple command returned rows`.

## 0.0.16

### Changed

- Cache compiled SQL by relation shape. Repeated queries that differ only in bound values copy the stored SQL text instead of rendering it again; the walk that builds the cache key also collects the binds. Every current identifier is validated before it enters the key; field separators are outside that alphabet, keeping keys unambiguous even when exposed strings or metadata are mutated. The key is read from the relation and model on every compile, so queries can be extended after `to_sql` and follow current metadata. Relations with JOINs, GROUP BY, HAVING, CTEs, subqueries, functions, `LIKE`, `OFFSET`, or an `IN` list longer than 32 values keep compiling on every call.
- Bound the SQL cache to two generations of 2048 entries under one mutex. New forms are admitted after capacity is reached, and hits in the older generation are promoted. Keys over 8 KiB and entries whose key plus SQL exceeds 16 KiB are not retained. The store owns frozen copies of its keys and SQL; callers receive mutable private SQL strings and fresh bind arrays.
- Check identifiers with a byte loop instead of a regular expression; the accepted set is unchanged (`[A-Za-z_][A-Za-z0-9_]*`).
- `pick` derives one relation instead of three, `select` with plain expressions skips flattening, and `compare` no longer allocates an operator list. Table aliases are still validated when a column is constructed, and derived relations keep independent preload lists.

### Performance

- The final source tree has a reproducible SQL/bind preparation benchmark in `bench/db/orm_compile.rb`. Results and the exact validation scope are recorded in `docs/orm-review/REVIEW.md`; measurements of earlier 0.0.16 candidates do not establish performance of this tree.

### Fixed

- `eq(nil)` and `not_eq(nil)` no longer raise `TypeError: no implicit conversion from nil to integer` when the same program also compares with an Integer. Spinel `9d10403` types the parameter as Integer when `nil` only reaches it through a receiver of more than one class (such as `table[:name]`, which can return a column or `*`); `eq` and `not_eq` now default their value to `nil`, which keeps the parameter nilable. Calling them without an argument builds `IS NULL` / `IS NOT NULL`. This made `test/db/arel_builder_test.rb` fail on 0.0.15 as well.
- Invalid dialects cannot reuse cached MySQL SQL. Cache admission checks bind counts without invoking comparison or identity methods on bound values; unsupported shapes clear any partially collected binds before using the ordinary renderer.
- The numeric test avoids Spinel's code-generation failure for `e.class.name` on a union of exception classes by rescuing the expected classes explicitly. It asserts the exact computed signed minimum instead of expecting a compiler-dependent `TypeError` for that valid value.
- TLS TSan now runs with a separately built, pinned and instrumented OpenSSL. The old Linux gate could report a false race in OpenSSL's lockless hashtable because only the harness was instrumented. The test preloads the exact crypto dependency without changing the symbolizer's library search path, reports its compiler/source provenance, and fails if OpenSSL is unavailable. Normal TLS runtime selection and the native lifecycle check are retained; see `docs/orm-review/TLS_TSAN.md`.

### Added

- `test/db/nil_compare_test.rb`: `eq`/`not_eq` with `nil` through a table column alongside Integer comparisons; it fails on 0.0.15 with the pinned Spinel.
- `test/db/shape_cache_test.rb`: differential test that compiles each shape directly, on a cache miss, and on a cache hit and requires identical SQL and binds; it also covers unaliased subquery projections, independent `Model.all`/`Model.table`, live column metadata, branching after `to_sql`, private copies of the returned text, pagination and long `IN` lists bypassing the cache, the identifier check, and 8000 compiles from four threads.
- `test/db/shape_cache_regression_test.rb`: malformed/mutated identifiers, dialect isolation, live metadata and root identity, opaque bound values, ownership of cached strings, byte limits, generation turnover/promotion, and 20 000 compiles during concurrent eviction and clearing.
- `test/db/pick_test.rb`: executes `pick` at a captured execution boundary and checks its SQL and unchanged receiver, including grouped/derived queries, existing order/window/projection, empty results, invalid inputs, and preload ownership.
- `ci/db-offline.sh`: runs the 14 database-independent DB tests, including the numeric and cache regressions. The signed-minimum probe now asserts correct minimum values and an actual nil branch instead of recording an older compiler's incorrect nil comparisons. The main `ci/run.sh` invokes the offline suite without requiring running DB services.

## 0.0.15

### Changed

- Pin Docker and both CI workflows to Spinel `9d10403754b91db4df7555b482c7c1436b0ddb52`.
- Include the PostgreSQL and MySQL/MariaDB adapters in the default `spin build` and `ext/build.sh`. Building requires libpq 17+ and MariaDB Connector/C 3.4+ development headers; set `KILN_DB=0` for an HTTP-only native build.
- Use Ubuntu 26.04 for the Docker build image to provide the required database development packages.

### Fixed

- Make the DB Ruby sources compile with the pinned Spinel version, including batch status writes and numeric bounds checks.
- Replace unsupported `String#byteindex` calls with the native byte-search helper.
- Extend the package installation smoke test to compile and run an application that requires `kiln/db`.

## 0.0.14

### Added

- Added bounded, sharded `Kiln::Cache` with SIEVE eviction, backed by Verstable and rapidhash (MIT).
- Added cache fuzz, lifecycle, close/reopen stress, GC, sanitizer and benchmark checks.
- Cache operations try the shard lock first and use blocking FFI only when it is busy, so mutex waits do not hold up garbage collection.

### Changed

- Reduced CI fuzz and benchmark smoke durations.
- Removed unused `ext/croaring` sources.

### Fixed

- Keep cache benchmark seeds within the generator range, including runs with more than four threads.
- Native checks reject failed worker startup and use Bash for the DB script's `pipefail`.
- Cache close now waits for active calls, and exhausted handle generations are retired.
- Reject out-of-range integer arguments, report cache read allocation failures and preserve entries when a shard is busy.
- Correct `closed?` for copied wrappers, sweep budgets, TTL overflow and maximum entry limits.

## 0.0.12

### Changed

- Breaking: `ctx.res.websocket` checks the `Origin` header. By default (`origins: nil`) a browser handshake has to come from the request host and port, and on an HTTPS connection the origin has to be HTTPS too. An HTTPS origin is accepted on a plain-HTTP connection, so the default also works behind a proxy that terminates TLS. Any other origin, including `null`, gets 403. `origins: ["https://app.example.com"]` accepts the listed origins and `origins: ["*"]` keeps the previous behavior. A handshake without `Origin` is accepted as before. Behind a proxy that rewrites `Host`, forward the original host and port or list the origins.
- `ctx.res.upgrade` and `ctx.res.hijack` take `idle_timeout:` (default 60 seconds), a finite positive number of seconds; an Integer too large to convert to a finite Float is rejected. A `read` without `timeout:` waits at most that long; then the connection wrapper is marked closed and `read` returns nil, and the transport is released when the handler returns. Before, it waited 3600 seconds on the event backend and without limit on the base backend, so idle clients could hold upgraded connections, and base threads, indefinitely. `idle_timeout: nil` keeps the unbounded wait. A `read` with `timeout:` behaves as before. WebSocket connections are unchanged.
- `Kiln::Server::Base` defaults to `127.0.0.1` like `Kiln::Server::Event`. `Kiln::Server.new` still defaults both backends to `0.0.0.0`; this is now documented.
- A malformed chunked body gets the same 400 body, `malformed request body`, on both backends.
- GET_STARTED documents percent-decoding before route matching (and what a proxy ACL on the raw path misses), what `:name` and `*path` parameters can contain, that an absolute-form target replaces `Host`, and when `100 Continue` is sent and an unread body keeps the connection open.
- `ci/c-native.sh` also runs the TLS context lifecycle under TSan with the test certificate, adds the SSE4.2 differential target and `ext/kiln_pico_sse42.c` to the coverage report when that target is built, and keeps the unfiltered report as `http-coverage-all.txt`.

### Fixed

- WebSocket frames whose length encoding contained a zero byte were sent with that byte missing: empty messages and pongs, messages of 126 to 255 bytes, and messages whose length is a multiple of 256 below 65 536. Clients then misread the stream. Autobahn Testsuite went from 11 failed cases to none.
- A WebSocket frame with a non-minimal 16-bit or 64-bit length was accepted; it now closes with 1002, as RFC 6455 section 5.2 requires.
- A repeated `Cookie` header was joined with `, `, so `Cookie: a=1` and `Cookie: b=2` reached the handler as `a` = `1, b=2` and no `b`. Both header parsers join it with `; `.
- Log output written to a file or a pipe stayed in the IO buffer until about 4 KB more output arrived or the log was closed. The writer flushes after 50 ms without new lines and on close, and writes every line accepted before `close`; under a continuous stream of lines it does not flush, and access-logged throughput is unchanged.
- On Spinel `519280dc9`, `return out << byte if condition` dropped a zero `byte`, which caused the WebSocket length bug above. The frame header is now built with separate statements. A module with `class << self` nested in `Kiln::HTTP::WebSocket` changed the compiled shutdown path, so the origin policy lives in `Kiln::HTTP::WsOrigins`.

## 0.0.11

### Changed

- Breaking: `Kiln::Server.new`, `Kiln::Server::Event.new` and `Kiln::Server::Base.new` take only the handler; the unused second positional application argument was removed. `Kiln::Server.new(router, log: log, ...)` replaces `Kiln::Server.new(router, nil, log: log, ...)`.
- `Kiln::Routing::Context.new(req, res, id, deadline)` no longer takes the application slot, and `Kiln::Routing::Context#app` was removed. `Kiln::Testing.call`/`.json` no longer accept the `state:` option, which only populated that slot. No other accept/return contract changed.
- Import accepts the activerecord-import input forms, selected update columns, conflict targets, column mappings, batch sizes, validation failure tracking, and result accessors. MySQL/MariaDB duplicate ignore and ordinary unique-key upserts are supported.
- Import defaults now follow AR Import for partial validation and timestamps. `import!` forces validation; `timestamps: false` and `all_or_none: true` select the explicit alternatives. The existing boolean upsert and result status APIs remain available.
- Query construction uses `Model.table`, Arel predicates and JOINs, aliases, expression projections, subqueries, aggregates, CASE, windows, set operations, and nonrecursive CTEs. Simple WHERE hashes and the existing query API remain supported.
- SQL values remain bind parameters throughout the expression tree. Native FFI declarations and C sources are unchanged.

## 0.0.10

### Changed

- Server settings are one `Settings` object over a defaults table and a rules table; each reader returns its own type (`Integer`, `Float`, `String`, `Tls`, `Log`). The handler and the application are passed to the engine as arguments and are never stored in settings.
- Gzip compresses response bodies larger than 256 KB in 64 KB pieces, so a large response no longer holds up garbage collection in other threads for the whole compression.
- An idle keep-alive connection returns its read and write buffers to a small shared pool and holds about 1 KB instead of about 9 KB.
- With `handlers: N`, a free handler takes the next request of any connection. Requests of one connection still run in order, and a slow handler delays only its own connection.
- Integer, boolean, and `DOUBLE`/`float8` columns reach Ruby without a text round trip. PostgreSQL asks for binary results for cached statements whose columns all have such types or `text`, `varchar`, or `bytea`. `pluck` of one column builds no row arrays.
- A PostgreSQL `import` without `returning` or conflict options uses `COPY` on tables where `COPY` writes the same as `INSERT`.
- Driver calls on different connections no longer wait for one registry lock.
- Status by item: P10-00, P10-01, P10-02, P10-03, P10-04 PASS; P10-05 DEVIATION (PostgreSQL and MySQL pass; MariaDB is 10% faster than the baseline, outside the literal ±5% band); P10-06, P10-07, P10-09 BLOCKED (need a Linux host with at least 6 cores); P10-08 BLOCKED by contract requirement 3, with a per-slot lock shipped outside the contract instead of the lock-free protocol; P10-10 PASS. See VALIDATION.md.

### Fixed

- On Spinel `2e5295be4` the server lost its handler and logger types when they went through `Data` options built from merged hashes: every request answered `NoMethodError: undefined method 'call' for Kiln::Routing::Router`. `log:` must now be a `Kiln::Observability::Log` or nil.
- Request registration during base-server shutdown returns an integer sentinel instead of a nil/integer union; static routing uses a local parameter key accepted by the updated compiler.
- The backpressure regression drains its socket without blocking Spinel's only worker and fails on a bounded deadline.
- Linux and macOS toolchain builds install Ruby and Prism for the updated Spinel build-time generators.
- A PostgreSQL `import` uses `COPY` only for a plain or partitioned table without rules, row-level security, or statement-level `INSERT` triggers. Before, `COPY` skipped `ON INSERT` rules and failed on tables with row-level security, so adding `returning: true` changed what a write did.
- A binary String with a NUL byte and no byte above 0x7F is sent to PostgreSQL as binary data; it was cut at the NUL. Any other String with a NUL byte raises `ArgumentError` on PostgreSQL instead of being cut.
- The event server stops reading, parsing, and starting handlers for a connection while 256 KiB of its responses are unsent, and resumes below 64 KiB. A client that pipelined requests without reading could make the server queue every response.
- The PostgreSQL driver reads from the server while it waits to send (`COPY`, queries, pipeline flushes), as libpq requires. A `COPY` into a table whose trigger sends notices could wait on the server until the timeout.
- A request the event server rejects with 400 or 501 is answered after the responses to the requests before it on the same connection, and the requests after it are not run. Before, the error went out first, closed the connection, and the earlier response was lost.
- `DISCARD PLANS`, `DISCARD SEQUENCES`, and `DISCARD TEMP` keep the PostgreSQL statement cache, `DEALLOCATE <name>` forgets one statement, and a missing statement (`26000`) forgets only itself. Before, any `DISCARD` or `DEALLOCATE` emptied the cache while the server kept the statements, so they piled up on the server.
- `import(returning: true)` raises `UnsupportedReturn` before writing when a `BEFORE` row trigger (or a PostgreSQL rule) could change the key used to match returned rows, and no longer pairs several unmatched rows with inputs by position.
- `tls: :disable` on MySQL and MariaDB turns off Connector/C 3.4's default TLS and certificate check, so it connects to a local server without TLS.
- A binary String with a backslash is sent to PostgreSQL as binary data; as text, `bytea` input read the backslash as an escape (`"\\x41".b` was stored as `A`). Binary strings with only ASCII bytes and no backslash or NUL stay text, so they still bind to numbers, dates, and `jsonb`.
- A PostgreSQL `import` uses `INSERT` instead of `COPY` for tables with a `GENERATED ALWAYS` identity column (on the table or its partition root), where `COPY` writes given values that `INSERT` refuses.
- A plain PostgreSQL `import` compares the affected row count of every `INSERT` page with the rows sent, as `COPY` already did, and rolls back with `InvariantViolation` when a `BEFORE` trigger skipped rows.
- An `import` takes `ROW EXCLUSIVE` on the table before it inspects rules, policies, and triggers, so they cannot change before the write. In `REPEATABLE READ` and `SERIALIZABLE` PostgreSQL transactions `import` uses `INSERT` and `returning: true` raises `UnsupportedReturn`, because their catalog snapshot can miss a concurrent change.
- On MySQL and MariaDB, `returning: true` requires a directly granted `TRIGGER` privilege, because `information_schema.triggers` hides triggers from other users, and requires a base table. Trigger and unique-index checks use the current database (`DATABASE()`) after `USE`.
- Returned rows whose key text differs from the input (padding, collation, numeric formatting) are matched with one primary-key lookup per page inside the import transaction.
- `DEALLOCATE` with comments, a quoted name right after the keyword, or form feeds is recognised by the PostgreSQL statement cache.
- The event server closes a connection on a read error other than end of input, and drops the queued requests of a connection that has gone instead of running their handlers.

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
