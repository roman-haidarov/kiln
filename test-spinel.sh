#!/bin/sh
set -eu

spinel_bin=${SPINEL:-spinel}
limit=${TEST_TIMEOUT:-120}
results_dir=${KILN_VALIDATION_DIR:-/tmp/kiln-validation}/tests
cd "$(dirname "$0")"
mkdir -p build/test
mkdir -p "$results_dir"
ext_links=$(./ext/build.sh)
total=0
failed=0

for source in test/*_test.rb; do
  total=$((total + 1))
  name=${source##*/}
  binary=build/test/${name%.rb}
  if [ ! -f "$source.expected" ]; then
    printf 'FAIL %s: missing Spinel snapshot %s.expected\n' "$name" "$source" >&2
    failed=$((failed + 1))
    continue
  fi
  if ! "$spinel_bin" $ext_links -I . "$source" -o "$binary"; then
    printf 'FAIL %s: compilation\n' "$name" >&2
    failed=$((failed + 1))
    continue
  fi
  result="$results_dir/$name.out"
  "$binary" > "$result" 2>&1 &
  pid=$!
  ticks=0
  status=0
  timed_out=0
  while kill -0 "$pid" 2> /dev/null; do
    process_state=$(ps -p "$pid" -o stat= 2> /dev/null || true)
    case "$process_state" in
      Z*) break ;;
    esac
    if [ "$ticks" -ge "$((limit * 10))" ]; then
      kill -9 "$pid" 2> /dev/null || true
      timed_out=1
      break
    fi
    sleep 0.1
    ticks=$((ticks + 1))
  done
  wait "$pid" || status=$?
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
