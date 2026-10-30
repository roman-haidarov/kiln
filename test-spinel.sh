#!/bin/sh
set -eu

limit=${TEST_TIMEOUT:-40}
results_dir=${KILN_VALIDATION_DIR:-/tmp/kiln-validation}/tests
cd "$(dirname "$0")"
spinel_bin=${SPINEL:-$(./ci/build-spinel.sh)/bin/spinel}
export SPINEL="$spinel_bin"
spinel_cc=$(pwd)/ci/spinel-cc.sh
export KILN_SPINEL_REAL_CC=${SPINEL_CC:-cc}
. ./ci/test-process.sh
mkdir -p build/test
mkdir -p "$results_dir"
ext_links=$(./ext/build.sh)
total=0
failed=0

if [ "$#" -eq 0 ]; then
  set -- test/*_test.rb
fi

for source in "$@"; do
  total=$((total + 1))
  name=${source##*/}
  binary=build/test/${name%.rb}
  result="$results_dir/$name.out"
  case "$source" in
    test/db/*)
      binary=build/test/db_${name%.rb}
      mkdir -p "$results_dir/db"
      result="$results_dir/db/$name.out"
      ;;
  esac
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
