#!/bin/sh
set -eu

spinel_bin=${SPINEL:-spinel}
cd "$(dirname "$0")/.."
spinel_cc=$(pwd)/ci/spinel-cc.sh
export KILN_SPINEL_REAL_CC=${SPINEL_CC:-cc}
mkdir -p build/test /tmp/kiln-gen-check
ext_links=$(KILN_DB=1 ./ext/build.sh)
"$spinel_bin" "--cc=$spinel_cc" $ext_links -I . test/db/gen_emit_test.rb -o build/test/db_gen_emit_test
out=$(build/test/db_gen_emit_test)
printf '%s\n' "$out" | tail -n 1 | grep -q 'ok gen-emit'
src=$(printf '%s\n' "$out" | sed '$d')
printf '%s\n' "$src" | grep -q 'define_table'
cat > /tmp/kiln-gen-check/check.rb << EOF
require 'kiln/db'
Thread.current
$src
print KilnGateCUser.table_name
print "\n"
print KilnGateCUser.columns.length.to_s
print "\n"
print KilnGateCUser.primary_key[0]
print "\n"
print "ok gen-compile\n"
EOF
"$spinel_bin" "--cc=$spinel_cc" $ext_links -I . /tmp/kiln-gen-check/check.rb -o /tmp/kiln-gen-check/check
got=$(/tmp/kiln-gen-check/check)
printf '%s\n' "$got" | grep -q 'kiln_gate_c_user'
printf '%s\n' "$got" | grep -q 'ok gen-compile'
printf '%s\n' "$got"
