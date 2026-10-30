#!/bin/sh
set -eu

results_dir=${KILN_VALIDATION_DIR:-/tmp/kiln-validation}/router-constants
mode=${1:-array}
seconds=${2:-10}
cd "$(dirname "$0")/.."
spinel_bin=${SPINEL:-$(./ci/build-spinel.sh)/bin/spinel}
export SPINEL="$spinel_bin"
spinel_cc=$(pwd)/ci/spinel-cc.sh
export KILN_SPINEL_REAL_CC=${SPINEL_CC:-cc}
mkdir -p build/bench "$results_dir"
ext_links=$(./ext/build.sh)
"$spinel_bin" "--cc=$spinel_cc" $ext_links --profile -I . bench/router_constants.rb -o build/bench/router_constants
build/bench/router_constants "$mode" "$seconds" > "$results_dir/$mode.out"
cat "$results_dir/$mode.out"
