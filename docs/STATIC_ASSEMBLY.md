# Class assembly

Spinel compiles the whole program ahead of time and keeps Ruby's rule that an
`include` in a later body of a class changes method lookup from that point
on. Kiln does not rely on that: every class is complete in its first body,
before any code can use it.

- A module is a reusable capability (`Runtime::Check`,
  `DB::QueryComposition`). Include it in the first body of its owner, after
  its dependencies have loaded.
- A file that only holds part of one class reopens that class and defines
  ordinary methods. It does not wrap them in a module of its own.
  `Kiln::Server`, its Event and Base backends, `DB::Conn`, `DB::Relation`
  and `Routing::Router` are split across files this way.
- A part that defines constants, calls `super`, overrides a method of
  another part or is shared by two owners is a module, not a part.

`ci/load-order.sh` compiles and runs a bare `require 'kiln'`, a require after
top-level code, DB-first loading and a constant lambda called before loading,
so a dependency on load order shows up in CI rather than in an application.

`ext/build.sh` builds first-party sources twice, plain and `_mt`, and lists
the plain objects; Spinel links the `_mt` companion for a threaded program
(`docs/internals/spin.md` in Spinel). Vendored libuv, zlib-ng and
picohttpparser objects do not touch Spinel runtime state and serve both.
