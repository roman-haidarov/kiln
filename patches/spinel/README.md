# Spinel patches

`ci/spinel-ref` pins the upstream commit. `ci/build-spinel.sh` checks and
applies `*.patch` files in filename order before compiling it. A failed
application stops the build.

`placement.patch` lets already created helpers participate in placement and
applies the same placement policy to threads spawned outside main. It changes
initial placement; running threads keep their worker.

`KILN_SCHED_HOLD_ACTIVE`, when set to a fifo path, stops each helper whose id
is at least `KILN_SCHED_HOLD_MIN_WID` (1 when unset) before that helper marks
itself active. The helper writes `<path>.wid<N>` and then reads one byte from
the fifo. Unset, the variable is a single lookup at helper start. The placement
test uses it to show that a created helper still receives new threads.

When updating the pinned commit, review the scheduler, update or remove the
patch, and run the placement and application tests described in
`docs/GET_STARTED.md`. Keep this directory when removing the final patch;
an empty patch set builds clean upstream through the same Docker/local/CI path.

`workers.patch` adds the Kiln runtime setting `KILN_WORKERS`. Its positive
value sets the application helper budget directly, independently of main.
It also exports `sp_sched_application_workers` so Kiln derives handler, shard
and database pool defaults from the same decision. With no Kiln setting,
upstream `SPINEL_WORKERS` and CPU detection retain their original semantics.
This patch is part of the managed toolchain fingerprint.
