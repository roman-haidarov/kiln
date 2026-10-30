#!/bin/sh
set -eu
unset KILN_WORKERS

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$root"
. ./ci/native-env.sh
my_prefix=$(ci/build-mariadb.sh --check)
kiln_mariadb_env "$my_prefix"
case "$(uname -s)" in
  Darwin) export KILN_LIBMARIADB=$my_prefix/lib/mariadb/libmariadb.dylib ;;
  *) export KILN_LIBMARIADB=$my_prefix/lib/mariadb/libmariadb.so ;;
esac
prefix=$(ci/build-spinel.sh --check)
spinel=$prefix/bin/spinel
if [ -n "${SPINEL:-}" ] && [ "$SPINEL" != "$spinel" ]; then
  printf 'CI requires the managed Spinel: %s\n' "$spinel" >&2
  exit 1
fi
artifacts=${KILN_ARTIFACTS:-${TMPDIR:-/tmp}/kiln-ci}
bench=${CI_BENCH:-1}
c_compiler=${CC:-cc}
native_compiler=${KILN_NATIVE_CC:-clang}

command -v "$spinel" >/dev/null 2>&1 || { printf 'spinel not found: %s\n' "$spinel" >&2; exit 1; }
export SPINEL="$spinel"
export SPIN="$prefix/bin/spin"
mkdir -p "$artifacts"

{
  printf 'spinel: %s\n' "$("$spinel" --version 2>&1 | sed -n '1p')"
  printf 'system: %s\n' "$(uname -srm)"
  printf 'cc: %s\n' "$($c_compiler --version 2>&1 | sed -n '1p')"
} | tee "$artifacts/environment.txt"

cp "$prefix/share/kiln-spinel/recipe" "$artifacts/spinel-recipe.txt"
printf '== toolchain cache and patch failure checks\n'
ruby ci/build-lock-test.rb
ci/toolchain-test.sh
ci/mariadb-toolchain-test.sh
printf '== application toolchain cache checks\n'
ci/spin-wrapper-test.sh
printf '== Spinel placement from main and child threads\n'
ci/spinel-placement.sh

if [ "${CI_NATIVE_C:-0}" = 1 ]; then
  command -v "$native_compiler" >/dev/null 2>&1 || {
    printf 'native C compiler not found: %s\n' "$native_compiler" >&2
    exit 1
  }
  CC="$native_compiler" ci/uv-state.sh
  printf '== native C analysis, fuzzing, TSan and coverage\n'
  KILN_NATIVE_CC="$native_compiler" KILN_C_ARTIFACTS="$artifacts/c-native" \
    ci/c-native.sh all
  printf '== libuv 1.53 embedding and lifecycle smoke\n'
  KILN_NATIVE_CC="$native_compiler" ci/libuv-embedding.sh
fi

printf '== test suite, SPINEL_WORKERS=1\n'
SPINEL_WORKERS=1 KILN_VALIDATION_DIR="$artifacts/workers-1" ./test-spinel.sh
printf '== database compiler and ORM tests without database services\n'
for workers in 2 4; do
  printf '== application workers %s\n' "$workers"
  KILN_WORKERS=$workers KILN_VALIDATION_DIR="$artifacts/application-$workers" \
    ./test-spinel.sh test/event_loops_test.rb test/parallelism_test.rb test/tls_test.rb test/listen_test.rb
done
SPINEL_WORKERS=1 KILN_VALIDATION_DIR="$artifacts/db-offline" ci/db-offline.sh
printf '== cache mutex and concurrent garbage collection\n'
CC="$c_compiler" KILN_CACHE_TEST_DIR="$artifacts/cache-gc" ci/cache-gc.sh
printf '== spin package install and build smoke\n'
SPINEL="$spinel" ci/spin-build-smoke.sh

if [ "$bench" = 1 ]; then
  printf '== benchmark smoke\n'
  SPINEL_WORKERS=1 KILN_VALIDATION_DIR="$artifacts/bench-validation" RESULTS_DIR="$artifacts/bench" \
    DURATION=1 WARMUP=0 ROUNDS=1 CONNECTIONS=16 MODES="inline lanes server" FEATURES=text CLIENTS=wrk \
    SAMPLE=0 MEMORY=1 bench/regression.sh
  meta=$(find "$artifacts/bench" -name meta.txt -type f | sed -n '1p')
  [ -n "$meta" ] || { printf 'benchmark produced no meta.txt\n' >&2; exit 1; }
  dir=${meta%/meta.txt}
  for file in summary.tsv median.tsv gc.tsv allocations.tsv resident.tsv; do
    [ -s "$dir/$file" ] || { printf 'benchmark output missing or empty: %s\n' "$file" >&2; exit 1; }
  done
fi
printf '== ok\n'
