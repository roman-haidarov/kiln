#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
compiler=${CC:-cc}
spinel=${SPINEL:-spinel}
spinel_cc=$(pwd)/ci/spinel-cc.sh
export SPINEL_CC=${SPINEL_CC:-$compiler}
export KILN_SPINEL_REAL_CC=${SPINEL_CC:-cc}
output=${KILN_CACHE_TEST_DIR:-build/cache-native}
mkdir -p "$output"
"$compiler" -std=c11 -DSP_THREADS -Wall -Wextra -Werror -O2 -pthread \
  -c bench/cache_gc_gate.c -o "$output/gc-gate.o"
"$spinel" "--cc=$spinel_cc" --link "$output/gc-gate.o" -I . \
  test/fixtures/cache_gc_test.rb -o "$output/gc-gate"
for operation in get set delete; do
  SPINEL_WORKERS=2 "$output/gc-gate" "$operation"
done
