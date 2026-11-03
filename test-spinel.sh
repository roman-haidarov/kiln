#!/bin/sh
set -eu

limit=${TEST_TIMEOUT:-40}
prebuilt=${KILN_TEST_PREBUILT:-0}
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
jobs=${TEST_JOBS:-$(getconf NPROCESSORS_ONLN 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || printf 1)}
case "$jobs" in
  ''|*[!0-9]*|0) jobs=1 ;;
esac
total=0
failed=0

if [ "$#" -eq 0 ]; then
  set -- test/*_test.rb
fi

binary_for() {
  case "$1" in
    test/db/*) name=${1##*/}; printf 'build/test/db_%s\n' "${name%.rb}" ;;
    *) name=${1##*/}; printf 'build/test/%s\n' "${name%.rb}" ;;
  esac
}

result_for() {
  case "$1" in
    test/db/*) printf '%s/db/%s.out\n' "$results_dir" "${1##*/}" ;;
    *) printf '%s/%s.out\n' "$results_dir" "${1##*/}" ;;
  esac
}

mkdir -p "$results_dir/db"
if [ "$prebuilt" != 1 ]; then
  for source in "$@"; do
    [ -f "$source.expected" ] || continue
    binary=$(binary_for "$source")
    rm -f "$binary" "$(result_for "$source").compile" "$(result_for "$source").compile-failed"
    printf '%s\0%s\0%s\0' "$source" "$binary" "$(result_for "$source")"
  done | KILN_TEST_SPINEL="$spinel_bin" KILN_TEST_CC="$spinel_cc" KILN_TEST_LINKS="$ext_links" \
    xargs -0 -n 3 -P "$jobs" sh -c '
      "$KILN_TEST_SPINEL" "--cc=$KILN_TEST_CC" $KILN_TEST_LINKS -I . "$1" -o "$2" > "$3.compile" 2>&1 ||
        : > "$3.compile-failed"
    ' compile || true
fi

for source in "$@"; do
  total=$((total + 1))
  name=${source##*/}
  binary=$(binary_for "$source")
  result=$(result_for "$source")
  if [ ! -f "$source.expected" ]; then
    printf 'FAIL %s: missing Spinel snapshot %s.expected\n' "$name" "$source" >&2
    failed=$((failed + 1))
    continue
  fi
  if [ "$prebuilt" = 1 ]; then
    if [ ! -x "$binary" ] || [ "$source" -nt "$binary" ]; then
      printf 'FAIL %s: no current binary %s to reuse\n' "$name" "$binary" >&2
      failed=$((failed + 1))
      continue
    fi
  else
    if [ -f "$result.compile-failed" ] || [ ! -x "$binary" ]; then
      cat "$result.compile" >&2 2>/dev/null || true
      printf 'FAIL %s: compilation\n' "$name" >&2
      failed=$((failed + 1))
      continue
    fi
    cat "$result.compile"
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
