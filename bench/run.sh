#!/bin/sh
set -eu

spinel_bin=${SPINEL:-spinel}
cd "$(dirname "$0")/.."
mkdir -p build/bench
results_dir=${KILN_VALIDATION_DIR:-/tmp/kiln-validation}/bench
mkdir -p "$results_dir"
ext_links=$(./ext/build.sh)
for name in route_bench wire_bench parse_bench pool_bench cpu_bench; do
  "$spinel_bin" $ext_links --profile -I . "bench/$name.rb" -o "build/bench/$name"
  "./build/bench/$name" > "$results_dir/$name.out"
  cat "$results_dir/$name.out"
  SPINEL_ALLOC_REPORT="$results_dir/$name.folded" SPINEL_ALLOC_SITES=1 "./build/bench/$name" > /dev/null
  printf '%s allocations=%s bytes=%s\n' "$name" "$(awk '/^alloc;/ {s += $NF} END {print s}' "$results_dir/$name.folded")" "$(awk '/^# bytes / {s += $NF} END {print s}' "$results_dir/$name.folded")" | tee -a "$results_dir/summary.txt"
done
for name in http_server http_client stress_server parse_driver; do
  "$spinel_bin" $ext_links --profile -I . "bench/$name.rb" -o "build/bench/$name"
done
