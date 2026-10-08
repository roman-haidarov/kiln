#!/bin/sh
set -eu

spinel_bin=${SPINEL:-spinel}
results_dir=${KILN_VALIDATION_DIR:-/tmp/kiln-validation}/router-constants
mode=${1:-array}
seconds=${2:-10}
cd "$(dirname "$0")/.."
mkdir -p build/bench "$results_dir"
ext_links=$(./ext/build.sh)
"$spinel_bin" $ext_links --profile -I . bench/router_constants.rb -o build/bench/router_constants
build/bench/router_constants "$mode" "$seconds" > "$results_dir/$mode.out"
cat "$results_dir/$mode.out"
