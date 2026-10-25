# Kiln::DB

Kiln::DB provides database connections, models, relations, transactions, and
bulk imports for Spinel applications. The application entry point creates the
connection; model and query examples are grouped below by task.

**Status: experimental in 0.0.8.** The MySQL 8.4 / MariaDB 11.4 /
PostgreSQL 17–18 server matrix, macOS and a CI job are still open release gates.

## Adapters

| Database | Connection kind | Model dialect | Client library |
| --- | --- | --- | --- |
| PostgreSQL | `Kiln::DB::Native::KIND_PG` | `:postgres` | [libpq](https://www.postgresql.org/docs/current/libpq.html) 17 or newer |
| MySQL | `Kiln::DB::Native::KIND_MY` | `:mysql` | [MariaDB Connector/C](https://mariadb.com/docs/connectors/mariadb-connector-c/) 3.4 or newer |
| MariaDB | `Kiln::DB::Native::KIND_MY` | `:mysql` | [MariaDB Connector/C](https://mariadb.com/docs/connectors/mariadb-connector-c/) 3.4 or newer |

Both client libraries are loaded with `dlopen` when the first connection opens
(`KILN_LIBPQ` and `KILN_LIBMARIADB` select a specific file). Their headers are
needed only to compile the database extension.

### Building

Kiln::DB is not part of the default build. `spin build` and `ext/build.sh`
compile Kiln without it and need no database headers. Build the database
extension explicitly:

```sh
KILN_DB=1 KILN_DB_LIBPQ_PREFIX=/opt/libpq17 KILN_DB_LIBMARIADB_PREFIX=/opt/mariadb-connector-c ./ext/build.sh
```

Without the prefixes the script asks `pkg-config` (`libpq`, `libmariadb`), then
`mariadb_config`, then the Homebrew paths. Compilation stops with an explicit
error when the headers are older than libpq 17 or Connector/C 3.4. A program
that requires `kiln/db` must be linked with these objects; `spin build` does not
provide them in this release.

### Connecting

```ruby
pool = Kiln::DB::Pool.new(4, timeout: 1.0) do
  Kiln::DB::Conn.open(Kiln::DB::Native::KIND_PG, host, 5432, user, password, database,
                      "/etc/ssl/db-ca.pem", "db.internal", timeout: 15.0)
end
Kiln::DB::Scope.pool = pool
```

`Conn.open(kind, host, port, user, password, database, ca, tls_name, tls:, timeout:, statement_cache:)`:

- `tls: :verify_full` (the default) requires a CA file and a TLS server name
  and verifies the certificate against that name. PostgreSQL also accepts
  `ca: :system` (libpq's `sslrootcert=system`); MySQL and MariaDB need a CA file.
  An empty CA is a `ConfigError` before any network I/O.
- `tls: :disable` is an explicit opt-in and is accepted only for `127.0.0.1` or
  `::1`. Unix sockets are not supported. The connection is plaintext: on
  MySQL and MariaDB Kiln turns off Connector/C's default TLS and certificate
  checks, so it also reaches a local server without TLS.
- PostgreSQL connects to `host` and verifies the certificate against
  `tls_name`. A host name is resolved off the calling thread (libuv
  `getaddrinfo`, bounded by `timeout:`); libpq gets up to 8 resolved addresses
  and tries them in order. MySQL and MariaDB
  under `verify_full` connect to `tls_name` (Connector/C verifies the name it
  connects to), so `host` is informational there.
- `timeout:` bounds every database operation. Inside a Kiln request the
  request deadline (`request_timeout`) is used when it is earlier.
- `statement_cache:` keeps prepared statements on the connection. The default
  is 32. `statement_cache: 0` turns the cache off. Any value other than an
  integer from 0 through 256 raises `ConfigError` before the driver connects.
  The cache is keyed by the SQL text alone, and a pool keeps one cache per
  connection.
  - MySQL and MariaDB reuse the prepared statement from the first execution
    of a text. Each cached statement counts toward `max_prepared_stmt_count`,
    so the server limit has to cover pool size × cache capacity. A cached
    statement keeps the default database and SQL mode it was prepared with,
    so on a connection that runs `USE` or changes `sql_mode`, use qualified
    table names or `statement_cache: 0`.
  - PostgreSQL prepares a named statement (`kiln_s<N>`) the second time the
    same text runs outside pipeline mode; the first run uses the unnamed
    statement as before. The least recently used statement is closed when the
    cache is full. `DISCARD ALL` and `DEALLOCATE ALL` run through `exec` empty
    the cache, `DEALLOCATE <name>` forgets that one statement, and `DISCARD
    PLANS`, `DISCARD SEQUENCES` and `DISCARD TEMP` keep it, because the server
    keeps the statements. `ALTER`, `CREATE`, `DROP` or `TRUNCATE` run through `exec` make
    the next use prepare again. When another session changes a table so that a
    cached statement returns different columns, PostgreSQL reports `0A000`
    (`cached plan must not change result type`); outside a transaction Kiln
    drops the statement and runs the query again unprepared, inside a
    transaction the error is raised and the transaction rolls back. A missing
    statement (`26000`) is handled the same way; only that statement is
    forgotten. The server chooses custom or
    generic plans for cached statements (`plan_cache_mode`). PgBouncer in
    transaction pooling needs `max_prepared_statements` (version 1.21 or
    later) or `statement_cache: 0`.

`Kiln::DB::Pool.new(size, timeout:) { Conn.open(...) }` hands each thread its own
connection. A connection that timed out, lost its server, or is left inside a
transaction is closed instead of being returned to the pool.
`pool.close(timeout: 5.0)` stops new checkouts (they raise `ConnectionError`),
closes idle connections, and waits up to `timeout` seconds for leased ones to
come back; it returns how many were still out (`0` when all came back). `Scope.pool = pool` lets
models and relations lease a connection; `Scope.use(conn)` pins one connection
to the current thread (scripts and tests).

Kiln::DB does not run on an inline event-loop handler: with the event backend
and `handlers: 0`, a database call raises `Kiln::DB::Unsupported` before any
I/O, because a database wait would stop every other connection. Use
`handlers: N` or the base backend.

## Models

Define the table, dialect, declared columns, primary key, and SQL alias. Column
names are strings. Associations are declared on the model classes.

```ruby
require "kiln/db"

class User < Kiln::DB::Model
  def validate
    "name required" if attrs["name"] == nil
  end
end

class Post < Kiln::DB::Model
end

class Tag < Kiln::DB::Model
end

User.define_table(:postgres, "users", ["id", "name", "active"], ["id"], "u")
Post.define_table(:postgres, "posts", ["id", "user_id", "title"], ["id"], "p")
Tag.define_table(:postgres, "tags", ["id", "label"], ["id"], "t")
User.has_many(:posts, Post, "user_id")
Post.belongs_to(:user, User, "user_id")
```

`attrs` stores a model's fields. `validate`, `before_save`, and `after_save`
can be overridden for validation and callbacks. Creating, updating, and
importing models is covered under [Writes and transactions](#writes-and-transactions).

## Queries and results

Start with `User.table` and use the Arel vocabulary. Table attributes accept
symbols or strings; SQL fragments are never needed by the builder. Values stay
in the separate bind array, including values inside projections, JOINs,
subqueries, functions, CASE expressions, and CTEs.

```ruby
user = User.table
User.where(user[:name].eq("Criss").and(user[:male].eq(true)).or(
  user[:age].gt(18).and(user[:age].lteq(40))
))
```

`User.arel_table` is another entry point. Simple filters accept hashes:

```ruby
User.where(name: "Criss", active: true)
User.where(id: [1, 2, 3])
User.where(age: 18...40)
User.where(name: [nil, "Criss"])
```

Relations and expression trees are immutable. Keep the returned relation when
building a query in several statements. `project` appends projections;
`select` replaces them. Compiling or reusing a query does not change its binds.

```ruby
users = User.where(active: true)
page = users.order(user[:id].asc).limit(20).offset(40)
sql, binds = page.compile
page.to_sql
page.to_binds
page.to_a
```

`to_sql` contains placeholders; `to_binds` contains values in SQL order.
PostgreSQL uses `$1`, `$2`, etc.; MySQL/MariaDB use `?`.

### Predicates and expressions

| Operation | Interface |
| --- | --- |
| Comparison | `eq`, `not_eq`, `gt`, `gteq`, `lt`, `lteq` |
| Boolean composition | `and`, `or`, `not` |
| NULL | `eq(nil)`, `not_eq(nil)` |
| Lists and subqueries | `in`, `not_in` |
| Ranges | `between(18..40)`, `between(18...40)`, `not_between(18..40)` |
| Pattern matching | `matches(pattern, escape = nil, case_sensitive = false)`, `does_not_match` |
| Ordering | `asc`, `desc` |
| Projection alias | `as(:name)` |
| Arithmetic | `+`, `-`, `*`, `/` |
| Aggregates | `count`, `count(true)`, `sum`, `average`, `minimum`, `maximum` |
| Text and defaults | `lower`, `upper`, `coalesce` |
| Function | `Kiln::DB::Arel::Nodes::NamedFunction.new(name, arguments)` |
| Wildcard | `table[:*]`, `Kiln::DB::Arel.star` |

Empty `in([])` compiles to FALSE and empty `not_in([])` to TRUE. Hash arrays
containing nil combine `IN` with `IS NULL`. Exclusive, beginless, and endless
ranges retain their boundary semantics. PostgreSQL `matches` uses ILIKE by
default and LIKE with `case_sensitive: true` supplied positionally as its third
argument; MySQL LIKE follows the column's collation.

```ruby
user = User.table
User.where(user[:age].gteq(18).and(user[:name].not_eq(nil)))
User.where(user[:name].matches("Cr%"))
User.select(user[:name].lower.as(:normalized_name))
User.select((user[:age] + 1).as(:next_age))
```

Legacy `Model.col`, `ne`, `gte`, `lte`, `like`, `null`, `not_null`, and the
existing `inner_join(other, on:)` family remain available.

### JOINs and aliases

Use `.join(...).on(...)` and compose the ON expression exactly like WHERE.
`join_sources` passes the resulting JOIN nodes to a model relation.

```ruby
user = User.table
post = Post.table
joins = user.join(post).on(
  post[:user_id].eq(user[:id]).and(post[:score].gt(5))
)
User.joins(joins.join_sources).select(user[:name], post[:title])
```

Outer JOINs use the Arel node names under `Kiln::DB::Arel::Nodes`:

```ruby
user = User.table
post = Post.table
user.join(post, Kiln::DB::Arel::Nodes::OuterJoin)
    .on(post[:user_id].eq(user[:id]))
    .project(user[:name], post[:title])
```

`InnerJoin`, `OuterJoin`, `RightOuterJoin`, `FullOuterJoin`, and `CrossJoin`
are supported. `outer_join(other)` is the LEFT JOIN shortcut. A CROSS JOIN
has no ON clause. A missing ON clause on another JOIN raises before execution.

```ruby
user = User.table
manager = user.alias(:manager)
user.join(manager).on(user[:manager_id].eq(manager[:id]))
    .project(user[:name], manager[:name].as(:manager_name))
```

PostgreSQL supports chains of FULL JOINs. MySQL's existing FULL JOIN rewrite
supports one FULL JOIN, using LEFT JOIN plus the unmatched right rows with
`UNION ALL` and `NOT EXISTS`; unsupported FULL JOIN chains raise `Unsupported`.

### Subqueries, set operations, and CTEs

```ruby
user = User.table
post = Post.table
ids = post.project(post[:user_id]).where(post[:score].gteq(10))
User.where(user[:id].in(ids))
User.where(post.where(post[:user_id].eq(user[:id])).exists)
User.where(user[:age].gt(post.project(post[:score].average)))
```

`IN` subqueries require one projected column. `.exists` builds a predicate;
`.exists?` executes a relation. Use `.as` to give a subquery a table alias:

```ruby
post = Post.table
user = User.table
scores = post.project(post[:user_id], post[:score].sum.as(:total))
             .group(post[:user_id]).as(:scores)
user.join(scores).on(scores[:user_id].eq(user[:id]))
    .project(user[:name], scores[:total])
```

```ruby
user = User.table
young = user.project(user[:id]).where(user[:age].lt(18))
old = user.project(user[:id]).where(user[:age].gt(40))
ages = young.union(:all, old).as(:ages)
ages.project(ages[:id])
```

`union(other)`, `union(:all, other)`, `union_all`, `intersect`, and `except`
compose queries with matching projection widths. Server support for INTERSECT
and EXCEPT depends on the selected database version.

```ruby
post = Post.table
scores = post.project(post[:user_id], post[:score].sum.as(:total))
             .group(post[:user_id]).as(:scores)
scores.project(scores[:user_id], scores[:total])
      .with(scores).where(scores[:total].gt(10))
```

`.with(Kiln::DB::Arel::Nodes::As.new(scores, scores.query))` also accepts the
Arel node form. CTEs are nonrecursive. JOINs can reference the same CTE.

### Aggregates, CASE, and windows

```ruby
post = Post.table
Post.select(post[:user_id], post[:score].sum.as(:total))
    .group(post[:user_id]).having(post[:score].sum.gt(10))
    .order(post[:user_id].asc)
```

```ruby
user = User.table
kind = Kiln::DB::Arel::Nodes::Case.new
       .when(user[:age].gteq(18)).then("adult").else("child")
User.select(user[:name], kind.as(:kind))
```

```ruby
post = Post.table
window = Kiln::DB::Arel::Nodes::Window.new
         .partition(post[:user_id]).order(post[:score].desc)
position = Kiln::DB::Arel::Nodes::NamedFunction.new("ROW_NUMBER", [])
           .over(window).as(:position)
Post.select(post[:id], position)
```

Windows support PARTITION BY and ORDER BY. Give computed derived-table columns
an explicit `.as` name before accessing them with `table[:name]`.

### Reading and loading

`to_a` returns arrays; `each`, `collect`, `map`, and `stream` expose `View::Row`.
`pluck` with one expression returns a flat array. `pick`, `first`, `first!`,
`ids`, `count`, `count_rows`, `count_root`, `exists?`, `sum`, `average`,
`minimum` through expression projections, and the existing `min`/`max`
relation methods remain available. `models` restores model instances for plain
model relations. `preload` retains the existing explicit association API.

```ruby
user = User.table
User.where(active: true).order(user[:id].asc).pluck(user[:name])
User.where(active: true).order(user[:id].asc).models
User.all.order(user[:id].asc).preload(:posts).models
```

Typed decoding is unchanged: PostgreSQL int2/int4/int8/bool/float8 and MySQL
integer/DOUBLE fast paths keep their existing Ruby representations. Decimal,
unsigned big integer, dates, and binary values retain the codec contracts.

### Direct SQL

Use `Conn#exec` when a relation is not the right fit. Put values in the bind
array. This raw SQL example uses PostgreSQL `$1` placeholders; MySQL uses `?`.
`Scope.lease` supplies the current scoped connection.

Execute a parameterized SQL query for active users:

```ruby
rows = Kiln::DB::Scope.lease do |conn|
  conn.exec("SELECT id, name FROM users WHERE active = $1", [true])
end
rows
=> [[1, "Rebecca"], [3, "Leon"]]
```

`Conn#exec` returns rows as arrays in column order. Values are converted by
column type:

| Column type | Ruby value |
| --- | --- |
| integer types | `Integer` (`UInt64Value` for MySQL `BIGINT UNSIGNED` above 2^63−1) |
| PostgreSQL `boolean` | `true` / `false` |
| MySQL `TINYINT(1)` / `BOOLEAN` | `Integer` (`1` / `0`): MySQL has no boolean type |
| `numeric` / `DECIMAL` | `ExactDecimal` |
| `real`, `double`, `FLOAT` | `Float` |
| `bytea`, `BLOB`, `BINARY`, `BIT` | `String` with `ASCII-8BIT` encoding |
| everything else (text, JSON, dates, times, UUID) | `String` with `UTF-8` encoding |
| `NULL` | `nil` |

Bind values may be `nil`, `true`/`false` (sent as `t`/`f` to PostgreSQL and
`1`/`0` to MySQL), `Integer`, finite `Float`, `String`, `Symbol`,
`ExactDecimal`, `Int64Value` and `UInt64Value`. A binary (`ASCII-8BIT`) string
with non-ASCII bytes, a NUL byte, or a backslash is sent as binary data, so a
`bytea` value reaches PostgreSQL unchanged (the `bytea` text input would read a
backslash as an escape). Such a value then has to fit the column's binary
format: `bytea`, `text`, `varchar` and `json` take it, `jsonb`, numbers, dates
and UUIDs do not; pass `UTF-8` strings for those. Other binary strings are sent
as text. On PostgreSQL any other `String` with a NUL byte raises
`ArgumentError`, because the text protocol cannot carry it. Any other object, including `Time`,
raises `ArgumentError`: format it as a string the database accepts. A statement
takes up to 65535 bound values; `import` splits its statements at 32767 values
and `preload` accepts up to 32767 parent keys.

Errors carry `sqlstate` and map to `UniqueViolation`, `ForeignKeyViolation`,
`NotNullViolation`, `CheckViolation`, `Deadlock`, `SerializationFailure`,
`LockWaitTimeout`, `Timeout` and `ConnectionError`; anything else is
`Kiln::DB::Error`.

## Writes and transactions

`assign` changes a declared field and marks it dirty. `save` inserts a new
model or updates changed fields; `save!` raises `Kiln::DB::RecordInvalid` when
validation fails.

```ruby
user = User.new({ "id" => 3, "name" => "Leon", "active" => true })
user.save!
user.assign("name", "Chris Redfield")
user.save!
```

`Model.import` follows activerecord-import's input forms and conflict-option
names. It accepts hashes, models, or an explicit list of columns followed by
rows. String and symbol column names are accepted.

```ruby
User.import([{ id: 1, name: "Ada" }, { id: 2, name: "Criss" }])
User.import([User.new(id: 1, name: "Ada")])
User.import([:id, :name], [[1, "Ada"], [2, "Criss"]])
User.import([:id, :name], models)
```

### Conflicts

```ruby
User.import(rows, on_duplicate_key_ignore: true)
User.import(rows, ignore: true)
User.import(rows, on_duplicate_key_update: [:name, :age])
```

Ignore skips a conflicting input without updating the existing record or
raising a duplicate-key exception. Rows without conflicts are inserted. Update
inserts new rows and updates the selected columns when a conflict occurs.
There are no `ignore_conflict` or `conflict_update` options.

PostgreSQL's array form uses the model primary key as the conflict target.
Choose another unique key or a named constraint with the AR Import hash form:

```ruby
User.import(rows, on_duplicate_key_update: {
  conflict_target: [:email], columns: [:name, :age]
})
User.import(rows, on_duplicate_key_update: {
  constraint_name: :users_email_key, columns: [:name]
})
User.import(rows, on_duplicate_key_update: {
  conflict_target: [:id], columns: { name: :display_name }
})
```

MySQL and MariaDB use any conflicting primary or unique index, as their servers
define. MySQL uses `INSERT IGNORE` and row-alias upserts; MariaDB uses
`INSERT IGNORE` and `VALUES(column)`. Column-to-column mappings use
`on_duplicate_key_update: { name: :display_name }` on MySQL/MariaDB.
Duplicate-key warnings do not become exceptions; other reported warnings retain
Kiln's rollback policy. The server's diagnostic-buffer limit applies when
inspecting MySQL warnings.

`:all` updates the imported non-key fields; the older `true` form remains
supported. An explicit update list must be nonempty and its source columns must
be present in every input shape. Timestamps are enabled by default, including
`updated_at`/`updated_on` on an upsert. `:all` preserves creation timestamps.
`timestamps: false` disables automatic timestamps and leaves exactly the supplied
update fields. Empty hashes use database default values.

### Batches and validation

```ruby
result = User.import(rows, batch_size: 500, on_duplicate_key_update: [:name])
result.failed_instances
result.num_inserts
result.affected_rows
result.ids
result.results
```

`batch_size` limits rows per SQL statement, including COPY chunks. The existing
1000-row and 32,767-bind safety limits still apply. All batches run inside one
transaction or the existing transaction's savepoint; failures roll them back.

Validation uses `Model#validate`. By default valid rows are imported and invalid
instances appear in `failed_instances`. Use `all_or_none: true` to reject the
whole input on validation failure, `validate: false` to skip validation,
`raise_error: true` to raise on the first invalid instance, or `import!` to force
validation and raise on failure. `track_validation_failures: true` returns
`[input_index, instance]` entries. `bulk_import` and `bulk_import!` are the AR
Import method aliases. Save callbacks are skipped.

The result preserves `state`, `length`, `input_status(index)`, and `returned`.
`num_inserts` counts write statements/COPY chunks; `affected_rows` sums the
server's affected-row counts. MySQL upserts can report two affected rows for one
updated input. Per-input status remains `applied_unknown` where the server
cannot distinguish inserts, updates, or skipped rows reliably.

```ruby
result = User.import(rows, returning: [:name])
result.ids
result.results
result.returned
```

`returning: true` returns all declared columns. A symbol or array selects
`results`; `returned` keeps the full rows. One requested result column yields a
flat array. `ids` is populated when rows are returned. Existing returning guards
remain: inputs need explicit complete primary keys; trigger/rule checks protect
matching, and MySQL returning upserts require a single unambiguous primary-key
conflict. These extra returning guards do not restrict ordinary MySQL imports
or upserts. Imported model instances are not refreshed automatically.

`require_exact_status` remains an explicit Kiln extension: it raises before
writing when the requested per-input status cannot be established. Recursive
association imports, ActiveRecord validators, callbacks, SQL-string update
clauses, synchronization, and partial-index SQL clauses are outside this API.
Unknown options raise; no Rails/ActiveRecord runtime dependency is added.

Plain eligible PostgreSQL imports retain the COPY path. COPY eligibility,
transaction ownership, native codecs, and FFI signatures are unchanged. Rules,
row-level security, identity columns, statement triggers, binary values, and
unstable catalog snapshots retain their existing INSERT fallback.

Reference interfaces: [activerecord-import](https://github.com/zdennis/activerecord-import)
and [Arel](https://github.com/rails/arel). The runnable builder and import
contracts are in `test/db/arel_builder_test.rb` and `test/db/ar_import_test.rb`.

Use `Kiln::DB.transaction` to group writes. Nested calls use savepoints; an
exception rolls back the current transaction scope and propagates to the
caller. A failed `COMMIT` raises the server error (the transaction is then
rolled back); a `COMMIT` whose outcome cannot be known (lost connection,
timeout) raises `UnknownCommitOutcome` and discards the connection. After a
MySQL deadlock inside a nested scope the server has rolled back the whole
transaction; further statements in it raise `PoisonedTransaction`.

```ruby
Kiln::DB.transaction do
  User.import([{ "id" => 5, "name" => "Rebecca", "active" => true }])
  Post.import([{ "id" => 13, "user_id" => 5, "title" => "Notes" }])
end
```

## Schema and numeric values

`Schema.columns(connection, table)` and
`Schema.primary_key(connection, table)` read table metadata.
`Generate.models(dialect, tables)` creates Spinel model source from metadata;
each generated model uses its table name as its SQL alias.
`Int64Value`, `UInt64Value`, and `ExactDecimal` preserve database numeric
values without converting them through floating point.
