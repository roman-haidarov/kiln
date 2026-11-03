# Spinel patches

`ci/spinel-ref` pins the upstream commit. `ci/build-spinel.sh` checks and
applies `*.patch` files in filename order before compiling it. A failed
application stops the build.

Only `placement.patch` and `workers.patch` are applied in production. Neither
changes parsing, type inference, mixin lookup or generated guard functions.
Kiln uses ordinary class definitions for implementation parts that have one
owner; shared mixins are included in their owner's first class body. See
`docs/STATIC_ASSEMBLY.md`. Upstream's late-include semantics are preserved.

`placement.patch` lets already created helpers participate in placement and
applies the same placement policy to threads spawned outside main. It changes
initial placement; running threads keep their worker.

Production does not contain the FIFO hold hook. The deterministic inactive
worker test uses `ci/fixtures/spinel-placement-hold.patch`, applied only with
`KILN_SPINEL_TEST_HOOKS=1`. Run `ci/scheduler-test-runtime.sh` for its separate
`.tools/spinel-test` toolchain. The build recipe distinguishes test and
production runtimes; do not use the test prefix for application builds.

When updating the pinned commit, review the scheduler, update or remove the
patch, and run the placement and application tests described in
`docs/GET_STARTED.md`. Keep this directory when removing the final patch;
an empty patch set builds clean upstream through the same Docker/local/CI path.

`workers.patch` adds the Kiln runtime setting `KILN_WORKERS`. Its positive
value sets the application helper budget directly, independently of main.
It also exports `sp_sched_application_workers` so Kiln derives handler and shard
defaults from the same decision, and sizes the GC budget for
the worker pool from it as well. With no Kiln setting,
upstream `SPINEL_WORKERS` and CPU detection retain their original semantics.
Invalid Kiln values raise `ArgumentError`; the library does not exit. DB pool
capacity is configured separately and defaults to 16 per pool.
This patch is part of the managed toolchain fingerprint.
