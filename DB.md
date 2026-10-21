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

`Conn.open(kind, host, port, user, password, database, ca, tls_name, tls:, timeout:)`:

- `tls: :verify_full` (the default) requires a CA file and a TLS server name
  and verifies the certificate against that name. PostgreSQL also accepts
  `ca: :system` (libpq's `sslrootcert=system`); MySQL and MariaDB need a CA file.
  An empty CA is a `ConfigError` before any network I/O.
- `tls: :disable` is an explicit opt-in and is accepted only for `127.0.0.1` or
  `::1`. Unix sockets are not supported.
- PostgreSQL connects to `host` and verifies the certificate against
  `tls_name`. A host name is resolved off the calling thread (libuv
  `getaddrinfo`, bounded by `timeout:`); libpq gets up to 8 resolved addresses
  and tries them in order. MySQL and MariaDB
  under `verify_full` connect to `tls_name` (Connector/C verifies the name it
  connects to), so `host` is informational there.
- `timeout:` bounds every database operation. Inside a Kiln request the
  request deadline (`request_timeout`) is used when it is earlier.

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

Relations start with `Model.all`. Conditions use column expressions, and values
are bound separately from SQL. Identifiers come from declared columns or
validated aliases. Relations can also be composed with `distinct`, `from`,
`group`, `having`, `order`, `limit`, and `offset`.

The results below are PostgreSQL's; `test/db/docs_examples_test.rb` runs every
example on PostgreSQL and MySQL. On MySQL the `active` column is `TINYINT(1)`
and reads back as `1` / `0`. For the examples below, assume these rows in `users`:

```text
id  name     active
1   Rebecca  true
2   Ada      false
3   Leon     true
```

and these rows in `posts`:

```text
id  user_id  title
10  1        Notes
11  1        Draft
12  2        Guide
```

and these rows in `tags`:

```text
id  label
1   Alpha
4   Umbrella
```

### Loading records and associations

**Load users in ID order and read their attributes.**

```ruby
users = User.all.order(User.col("id").asc).models
users.map { |user| user.attrs }
=> [{"id" => 1, "name" => "Rebecca", "active" => true}, {"id" => 2, "name" => "Ada", "active" => false}, {"id" => 3, "name" => "Leon", "active" => true}]
```

**Preload each user's posts and collect their titles.**

```ruby
users = User.all.order(User.col("id").asc).preload(:posts).models
users.map { |user| user.assoc(:posts).map { |post| post.attrs["title"] } }
=> [["Notes", "Draft"], ["Guide"], []]
```

### Filters, boolean conditions, and ordering

Column expressions include `eq`, `ne`, `gt`, `gte`, `lt`, `lte`, `in`,
`not_in`, `between`, `like`, `null` (alias `is_null`), and `not_null`. Combine predicates
with `and`, `or`, and `not`.

**Select active users and order them by name.**

```ruby
users = User.all.where(User.col("active").eq(true))
users.order(User.col("name").asc).pluck(User.col("name"))
=> ["Leon", "Rebecca"]
```

**Combine an active-user condition with a name match using `or`.**

```ruby
users = User.all.where(User.col("active").eq(true).or(User.col("name").eq("Ada")))
users.order(User.col("id").asc).pluck(User.col("name"))
=> ["Rebecca", "Ada", "Leon"]
```

**Find users whose IDs are in an inclusive range.**

```ruby
users = User.all.where(User.col("id").between(1, 2))
users.order(User.col("id").asc).pluck(User.col("name"))
=> ["Rebecca", "Ada"]
```

**Select users whose IDs match one of the listed values.**

```ruby
users = User.all.where(User.col("id").in([1, 3]))
users.order(User.col("id").asc).pluck(User.col("name"))
=> ["Rebecca", "Leon"]
```

**Exclude users whose IDs appear in a list.**

```ruby
User.all.where(User.col("id").not_in([1, 3])).pluck(User.col("name"))
=> ["Ada"]
```

**Match names with a SQL `LIKE` pattern.**

```ruby
User.all.where(User.col("name").like("R%")).pluck(User.col("name"))
=> ["Rebecca"]
```

**Return one row from the second page with `limit` and `offset`.**

```ruby
users = User.all.order(User.col("id").asc).limit(1).offset(1)
users.pluck(User.col("name"))
=> ["Ada"]
```

### Selecting columns and reading rows

`pluck` returns an array of values for one column, or arrays of values for
multiple columns. `to_a` returns arrays in selected-column order. `first`
returns a row view that supports numeric indexing and `get(name)`.

**Select two columns and return each row as an array.**

```ruby
users = User.all.order(User.col("id").asc)
users.select(User.col("name"), User.col("active")).to_a
=> [["Rebecca", true], ["Ada", false], ["Leon", true]]
```

**Read IDs and names as two-value arrays.**

```ruby
users = User.all.order(User.col("id").asc)
users.pluck(User.col("id"), User.col("name"))
=> [[1, "Rebecca"], [2, "Ada"], [3, "Leon"]]
```

**Read a named value from the first selected row.**

```ruby
user = User.all.order(User.col("id").asc).select(User.col("name")).first
user.get("name")
=> "Rebecca"
```

**Map row views to values with `collect`.**

```ruby
users = User.all.order(User.col("id").asc)
users.collect { |row| row.get("name") }
=> ["Rebecca", "Ada", "Leon"]
```

**Read values by numeric row index with `map`.**

```ruby
users = User.all.order(User.col("id").asc).select(User.col("id"), User.col("name"))
users.map { |row| row[1] }
=> ["Rebecca", "Ada", "Leon"]
```

### Counts and single-value results

`count` returns an integer. `ids` returns one key array per row, `pick` returns
one value, and `exists?` returns a boolean.

#### Count all users

```ruby
User.all.count
=> 3
```

#### Count active users

```ruby
User.all.where(User.col("active").eq(true)).count
=> 2
```

#### Check for active users

```ruby
User.all.where(User.col("active").eq(true)).exists?
=> true
```

#### Count rows from a subquery

```ruby
users = User.all.from(User.all.where(User.col("id").eq(1)))
users.count
=> 1
```

#### Read primary keys

```ruby
User.all.order(User.col("id").asc).ids
=> [[1], [2], [3]]
```

#### Read one value with `pick`

```ruby
User.all.pick(User.col("name"))
=> "Rebecca"
```

#### Check for a specific user

```ruby
User.all.where(User.col("name").eq("Leon")).exists?
=> true
```

### Joins

Join conditions use column expressions. `count` on a joined relation counts
joined rows; `count_root` counts distinct root models.

#### Left join users and posts

Keep users with and without posts, and include the post title when present.

```ruby
users = User.all.left_join(Post, on: Post.col("user_id").eq(User.col("id")))
users = users.order(User.col("id").asc, Post.col("id").asc)
users.select(User.col("name"), Post.col("title")).to_a
=> [["Rebecca", "Notes"], ["Rebecca", "Draft"], ["Ada", "Guide"], ["Leon", nil]]
```

#### Count joined rows

```ruby
users = User.all.inner_join(Post, on: Post.col("user_id").eq(User.col("id")))
users.count
=> 3
```

#### Count distinct root users

```ruby
users = User.all.inner_join(Post, on: Post.col("user_id").eq(User.col("id")))
users.count_root
=> 2
```

#### Join a table to itself

Use a second SQL alias for the joined copy of `users`.

```ruby
users = User.all.join_as(User, "u2", on: User.col("id").eq(Kiln::DB::Col.new("u2", "id")))
users.count
=> 3
```

#### Right join users and tags

Keep tags with or without a matching user.

```ruby
tags = User.all.right_join(Tag, on: Tag.col("id").eq(User.col("id")))
tags = tags.order(Tag.col("id").asc)
tags.select(User.col("name"), Tag.col("label")).to_a
=> [["Rebecca", "Alpha"], [nil, "Umbrella"]]
```

#### Count full-join rows

Include unmatched rows from either side.

```ruby
User.all.full_join(Tag, on: Tag.col("id").eq(User.col("id"))).count
=> 4
```

#### Count cross-join pairs

```ruby
User.all.cross_join(Tag).count
=> 6
```

`right_join` and `full_join` keep unmatched rows from the joined table;
`cross_join` returns every pair of rows. Relations also support `through`.

### Subquery existence

Find users with at least one related post:

```ruby
users = User.all.where_exists(Post.all.where(Post.col("user_id").eq(User.col("id"))))
users.order(User.col("id").asc).pluck(User.col("name"))
=> ["Rebecca", "Ada"]
```

Find users with no related posts:

```ruby
users = User.all.where_missing(Post.all.where(Post.col("user_id").eq(User.col("id"))))
users.order(User.col("id").asc).pluck(User.col("name"))
=> ["Leon"]
```

### Grouping and aggregates

Use `group` with `having` for grouped counts. `count` on a grouped relation
returns a `GroupedResult`; `to_a` returns pairs of group-key arrays and counts.
`sum`, `avg`, and `average` return `ExactDecimal`; `min` and `max` return the
database value.

Count posts per user:

```ruby
posts = Post.all.group(Post.col("user_id")).order(Post.col("user_id").asc)
posts.count.to_a
=> [[[1], 2], [[2], 1]]
```

Keep only groups with user ID 1:

```ruby
posts = Post.all.group(Post.col("user_id"))
posts.having(Post.col("user_id").eq(1)).count.to_a
=> [[[1], 2]]
```

Count posts for one user without grouping:

```ruby
Post.all.where(Post.col("user_id").eq(1)).count
=> 2
```

Sum post IDs and convert the exact decimal result to text:

```ruby
Post.all.sum(Post.col("id")).to_s
=> "33"
```

Other terminal methods include `models`, `to_a`, `each`, `map`, `pluck`,
`pick`, `ids`, `exists?`, `sum`, `sum_or_zero`, `avg`, `min`, and `max`.
`each`, `map` and `collect` load the whole result first, so the block can run
other queries.

`stream` reads the result in batches while the block runs, for results too
large to hold in memory. The connection is busy until the block returns: a
query, transaction or pipeline on it inside the block raises `Kiln::DB::Error`
and leaves the connection usable. Leaving the block early cancels the rest of
the query on PostgreSQL; on MySQL the remaining rows are read and dropped, and
the connection is discarded if that takes longer than two seconds.

```ruby
User.all.order(User.col("id").asc).stream { |row| out.write(row.get("name")) }
```

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
with non-ASCII bytes is sent as binary data. Any other object, including `Time`,
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

`Model.import` accepts arrays of hashes or model instances. Hash keys may be
strings or symbols. `import!` raises when validation rejects a row.

```ruby
result = User.import([
  { "id" => 3, "name" => "Leon", "active" => true },
  { :id => 4, :name => "Chris", :active => true }
])

result.state
result.length
result.input_status(0)
```

`ImportResult` exposes the overall state, input row count, per-input status,
and returned rows. Import options include `timestamps:`, `all_or_none:`,
`returning:`, `on_duplicate_key_ignore:`, and `on_duplicate_key_update:`.

A new model whose single primary key is missing gets the generated key back
after `save` (`RETURNING` on PostgreSQL, `LAST_INSERT_ID()` on MySQL).
`import` writes up to 1000 rows per `INSERT`, also with `returning: true`.
Returned rows are matched to inputs by primary key and listed in input order.
When the database treats two keys as equal that differ as text (a
case-insensitive collation, `citext`, decimal formatting) and the match is not
certain, the input gets `applied_unknown` and its row is listed after the
matched ones. Inside an outer transaction
`ImportResult#state` is `PENDING_COMMIT`: the outer transaction decides the
outcome. On MySQL, `on_duplicate_key_update:` uses the row alias form
(`VALUES (...) AS kiln_new`); MariaDB keeps `VALUES(col)`.

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
