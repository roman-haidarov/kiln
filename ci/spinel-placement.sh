#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$root"
spinel_cc=$(pwd)/ci/spinel-cc.sh
export KILN_SPINEL_REAL_CC=${SPINEL_CC:-cc}
spinel=${SPINEL:-$root/bin/spinel}
unset KILN_WORKERS
scratch=$(mktemp -d "${TMPDIR:-/tmp}/kiln-placement.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
. ./ci/test-process.sh
"$spinel_cc" -std=c11 -ftls-model=initial-exec -c ci/spinel-worker.c -o "$scratch/worker.o"
keep="-Wl,-u,kiln_ci_worker_id"
visible=
if [ "$(uname -s)" = "Darwin" ]; then
  keep="-Wl,-u,_kiln_ci_worker_id"
else
  visible="-Wl,--export-dynamic-symbol,kiln_ci_worker_id"
fi
"$spinel" "--cc=$spinel_cc" --link "$scratch/worker.o" --link "$keep" \
  ${visible:+--link "$visible"} \
  ci/spinel-placement.rb -o "$scratch/probe"
"$spinel" "--cc=$spinel_cc" --link "$scratch/worker.o" --link "$keep" \
  ${visible:+--link "$visible"} \
  ci/spinel-placement-hold.rb -o "$scratch/hold"
cat >"$scratch/budget.rb" <<'RUBY'
module WorkerBudget
  ffi_func :sp_sched_application_workers, [], :int
end
raise 'single-thread runtime budget' unless WorkerBudget.sp_sched_application_workers == 1
puts 'single-thread runtime budget ok'
RUBY
"$spinel" "--cc=$spinel_cc" "$scratch/budget.rb" -o "$scratch/budget"
(
  export KILN_WORKERS=4
  run_test_process "$scratch/budget" "$scratch/budget-result" 30
  cat "$scratch/budget-result" || exit "$?"
  exit "$status"
) || exit "$?"
for workers in 3 5; do
  (
    unset KILN_WORKERS
    export SPINEL_WORKERS=$workers
    run_test_process "$scratch/probe" "$scratch/result" 30
    cat "$scratch/result" || exit "$?"
    exit "$status"
  ) || exit "$?"
done
for workers in 1 2 4; do
  (
    export KILN_WORKERS=$workers SPINEL_WORKERS=1
    run_test_process "$scratch/probe" "$scratch/result" 30
    cat "$scratch/result" || exit "$?"
    exit "$status"
  ) || exit "$?"
done
mkfifo "$scratch/gate"
(
  unset KILN_WORKERS
  export KILN_SCHED_HOLD_ACTIVE="$scratch/gate" KILN_SCHED_HOLD_MIN_WID=2 SPINEL_WORKERS=3
  run_test_process "$scratch/hold" "$scratch/hold-result" 30
  cat "$scratch/hold-result" || exit "$?"
  exit "$status"
) || exit "$?"
