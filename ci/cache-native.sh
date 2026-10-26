#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
compiler=${CC:-clang}
output=${KILN_CACHE_TEST_DIR:-build/cache-native}
mkdir -p "$output"
mode=${1:-asan}
case "$mode" in
  asan) sanitizer=address,undefined ;;
  tsan) sanitizer=thread ;;
  *) printf 'usage: %s [asan|tsan]\n' "$0" >&2; exit 2 ;;
esac
"$compiler" -std=c11 -DSP_THREADS -Wall -Wextra -Werror -g -O1 \
  -fsanitize="$sanitizer" -fno-sanitize-recover=all -fno-omit-frame-pointer -pthread \
  bench/cache_lifecycle.c -o "$output/lifecycle-$mode"
"$output/lifecycle-$mode"
"$output/lifecycle-$mode" key-create
"$output/lifecycle-$mode" key-set
"$compiler" -std=c11 -DSP_THREADS -Wall -Wextra -Werror -g -O1 \
  -fsanitize="$sanitizer" -fno-sanitize-recover=all -fno-omit-frame-pointer -pthread \
  bench/cache_lifecycle_stress.c ext/kiln_cache.c -o "$output/lifecycle-stress-$mode"
"$output/lifecycle-stress-$mode"
"$compiler" -std=c11 -DSP_THREADS -Wall -Wextra -Werror -g -O1 \
  -fsanitize="$sanitizer" -fno-sanitize-recover=all -fno-omit-frame-pointer -pthread \
  bench/cache_tsan.c ext/kiln_cache.c -o "$output/stress-$mode"
"$output/stress-$mode"
