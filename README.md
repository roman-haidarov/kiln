<h1 align="center">Kiln</h1>

<h2 align="center">A native HTTP runtime for Spinel</h2>

<p align="center"><strong>Ruby-like code. Ahead-of-time compiled. Built for web applications.</strong></p>

---

## Why Kiln

Kiln began when [Spinel](https://github.com/matz/spinel) introduced ahead-of-time
compilation. It opened a path to native web applications written in a familiar,
Ruby-like language, with C handling performance-sensitive networking and
protocol work.

## What Kiln is

- [Spinel](https://github.com/matz/spinel) is the foundation: an ahead-of-time
  compiled, Ruby-like language and runtime. Kiln uses it for application code,
  memory management, scheduling, and calls between Ruby-like code and C.
- Kiln is a web framework and HTTP runtime for building native Spinel
  applications.
- [libuv](https://github.com/libuv/libuv) provides the cross-platform event loop
  and asynchronous network I/O used by Kiln's event server.
- [picohttpparser](https://github.com/h2o/picohttpparser) parses HTTP request
  headers with a small, focused C implementation.
- [yyjson](https://github.com/ibireme/yyjson) handles JSON parsing and
  generation through a fast C library.
- [zlib-ng](https://github.com/zlib-ng/zlib-ng) provides gzip compression with
  architecture-specific optimizations where available.
- [Verstable](https://github.com/JacksonAllan/Verstable) is the hash table
  and [rapidhash](https://github.com/Nicoshev/rapidhash) the hash function of
  `Kiln::Cache`, the off-heap key-value cache.
- [OpenSSL](https://github.com/openssl/openssl) provides TLS. Kiln loads the
  system OpenSSL library at runtime rather than bundling it.
- [libpq](https://www.postgresql.org/docs/current/libpq.html) connects Kiln::DB
  to PostgreSQL.
- [MariaDB Connector/C](https://mariadb.com/docs/connectors/mariadb-connector-c/)
  connects Kiln::DB to MySQL and MariaDB.

## Ideas behind it

| Project | What inspired Kiln |
| --- | --- |
| [Actix Web](https://github.com/actix/actix-web) | Explicit application composition and a clear separation of concerns |
| [Go net/http](https://github.com/golang/go/tree/master/src/net/http) | A practical, dependable HTTP server foundation |
| Rails | Organizing routes and controllers into focused application files |

Kiln brings these ideas together for Spinel: a small web runtime with explicit
routing, room to organize application code by layer, and native compilation.

## Get started

Kiln 0.0.18 builds its pinned, patched Spinel automatically. Run `bin/setup`
once, then use `bin/spin` or `bin/spinel` for application builds. Both commands
also set up a missing toolchain and check its fingerprint before use.
Start with `KILN_WORKERS=2 ./build/bin/my_app` for two application CPU workers.
Event handler concurrency, Base shards and the lazy database pool follow that
number automatically.

<p align="center"><a href="docs/GET_STARTED.md"><strong>Installation, examples, and usage →</strong></a></p>

Kiln::DB (experimental, built only on request) covers database adapters,
models, queries and result shapes: see [DB.md](DB.md).
