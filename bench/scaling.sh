#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
output=${RESULTS_DIR:-${TMPDIR:-/tmp}/kiln-scaling}
mkdir -p "$output"
output=$(CDPATH= cd -- "$output" && pwd -P)
"$root/bin/setup" >"$output/setup.log" 2>&1
spinel_cc=$root/ci/spinel-cc.sh
export KILN_SPINEL_REAL_CC=${SPINEL_CC:-cc}
project=$output/application
if [ ! -f "$project/spin.toml" ]; then
  (cd "$output" && "$root/bin/spin" new application) >"$output/new.log" 2>&1
fi
(cd "$project" && "$root/bin/spin" add kiln --path "$root") >"$output/add.log" 2>&1
cp "$root/bench/scaling_server.rb" "$project/bin/application.rb"
(cd "$project" && CC="$spinel_cc" "$root/bin/spin" build) >"$output/build.log" 2>&1
ruby "$root/bench/scaling.rb" "$project/build/bin/application" "$output"
