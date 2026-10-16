#!/bin/sh
set -eu

spinel=${SPINEL:-spinel}
artifacts=${KILN_ARTIFACTS:-${TMPDIR:-/tmp}/kiln-ci}
bench=${CI_BENCH:-1}
c_compiler=${CC:-cc}
native_compiler=${KILN_NATIVE_CC:-clang}

command -v "$spinel" >/dev/null 2>&1 || { printf 'spinel not found: %s\n' "$spinel" >&2; exit 1; }
export SPINEL="$spinel"
mkdir -p "$artifacts"

{
  printf 'spinel: %s\n' "$("$spinel" --version 2>&1 | sed -n '1p')"
  printf 'system: %s\n' "$(uname -srm)"
  printf 'cc: %s\n' "$($c_compiler --version 2>&1 | sed -n '1p')"
} | tee "$artifacts/environment.txt"

if [ "${CI_NATIVE_C:-0}" = 1 ]; then
  command -v "$native_compiler" >/dev/null 2>&1 || {
    printf 'native C compiler not found: %s\n' "$native_compiler" >&2
    exit 1
  }
  printf '== native C analysis, fuzzing, TSan and coverage\n'
  KILN_NATIVE_CC="$native_compiler" KILN_C_ARTIFACTS="$artifacts/c-native" \
    ci/c-native.sh all
fi

printf '== test suite, SPINEL_WORKERS=1\n'
SPINEL_WORKERS=1 KILN_VALIDATION_DIR="$artifacts/workers-1" ./test-spinel.sh

if [ "$bench" = 1 ]; then
  printf '== benchmark smoke\n'
  SPINEL_WORKERS=1 KILN_VALIDATION_DIR="$artifacts/bench-validation" RESULTS_DIR="$artifacts/bench" \
    DURATION=2 WARMUP=1 ROUNDS=1 CONNECTIONS=16 MODES="inline lanes server" FEATURES=text CLIENTS=wrk \
    SAMPLE=0 MEMORY=1 bench/regression.sh
  meta=$(find "$artifacts/bench" -name meta.txt -type f | sed -n '1p')
  [ -n "$meta" ] || { printf 'benchmark produced no meta.txt\n' >&2; exit 1; }
  dir=${meta%/meta.txt}
  for file in summary.tsv median.tsv gc.tsv allocations.tsv resident.tsv; do
    [ -s "$dir/$file" ] || { printf 'benchmark output missing or empty: %s\n' "$file" >&2; exit 1; }
  done
fi
printf '== ok\n'
