#!/bin/sh
set -eu

spinel_bin=${SPINEL:-spinel}
limit=${TEST_TIMEOUT:-40}
results_dir=${KILN_VALIDATION_DIR:-/tmp/kiln-validation}/db-tests
cd "$(dirname "$0")/.."
spinel_cc=$(pwd)/ci/spinel-cc.sh
export KILN_SPINEL_REAL_CC=${SPINEL_CC:-cc}
. ./ci/test-process.sh
mkdir -p build/test
mkdir -p "$results_dir"
pattern=${1:-}
if [ -n "$pattern" ]; then
  set -- test/db/*"$pattern"*_test.rb
else
  set -- test/db/*_test.rb
fi
if [ ! -f "$1" ]; then
  printf 'FAIL db-test: no match for %s\n' "${pattern:-all}" >&2
  exit 1
fi
ext_links=$(KILN_DB=1 ./ext/build.sh)
total=0
failed=0

for source in "$@"; do
  total=$((total + 1))
  name=${source##*/}
  binary=build/test/db_${name%.rb}
  if [ ! -f "$source.expected" ]; then
    printf 'FAIL %s: missing Spinel snapshot %s.expected\n' "$name" "$source" >&2
    failed=$((failed + 1))
    continue
  fi
  if ! "$spinel_bin" "--cc=$spinel_cc" $ext_links -I . "$source" -o "$binary"; then
    printf 'FAIL %s: compilation\n' "$name" >&2
    failed=$((failed + 1))
    continue
  fi
  result="$results_dir/$name.out"
  run_test_process "$binary" "$result" "$limit"
  if [ "$status" -ne 0 ]; then
    cat "$result" >&2
    if [ "$timed_out" -eq 1 ]; then
      printf 'FAIL %s: timeout after %ss\n' "$name" "$limit" >&2
    else
      printf 'FAIL %s: exit %s\n' "$name" "$status" >&2
    fi
    failed=$((failed + 1))
    continue
  fi
  if ! cmp -s "$source.expected" "$result"; then
    diff -u "$source.expected" "$result" >&2 || true
    printf 'FAIL %s: output differs from snapshot\n' "$name" >&2
    failed=$((failed + 1))
    continue
  fi
  printf 'ok   %s\n' "$name"
done

printf '%s/%s passed under Spinel\n' "$((total - failed))" "$total"
[ "$failed" -eq 0 ]
