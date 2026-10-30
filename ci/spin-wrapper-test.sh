#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$root"
spinel_cc=$(pwd)/ci/spinel-cc.sh
export KILN_SPINEL_REAL_CC=${SPINEL_CC:-cc}
export CC="$spinel_cc"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/kiln-spin-wrapper.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
cd "$scratch"
"$root/bin/spin" new wrapper_probe >/dev/null
cd wrapper_probe
printf "puts 'managed wrapper ok'\n" > bin/wrapper_probe.rb
touch -t 202001010000 spin.toml .gitignore bin/wrapper_probe.rb
mkdir -p build/bin build/test
printf 'legacy test output\n' > build/test/legacy
cat > build/bin/wrapper_probe <<'SH'
#!/bin/sh
printf 'wrong runtime\n'
SH
chmod +x build/bin/wrapper_probe
touch -t 203001010000 build/bin/wrapper_probe
"$root/bin/spin" build > "$scratch/build.log" 2>&1
[ "$(build/bin/wrapper_probe)" = 'managed wrapper ok' ]
[ ! -e build/test/legacy ]
[ -f build/.kiln-toolchain ]
printf 'ok wrapper rebuilds untagged binaries with future timestamps\n'

"$root/bin/spin" --verbose build > "$scratch/cached.log" 2>&1
grep -q 'up to date' "$scratch/cached.log"
printf 'ok matching toolchain keeps incremental builds\n'
printf 'old toolchain\n' > build/.kiln-toolchain
"$root/bin/spin" build --help > "$scratch/help.log" 2>&1
[ "$(cat build/.kiln-toolchain)" = 'old toolchain' ]
printf 'ok help leaves the application cache alone\n'
mkdir nested
cd nested
"$root/bin/spin" run -- --help > "$scratch/run.log" 2>&1
[ "$(tail -n 1 "$scratch/run.log")" = 'managed wrapper ok' ]
cd ..
printf 'ok run discovers the project and handles program arguments\n'

printf "puts 'managed test ok'\n" > test/probe_test.rb
printf 'managed test ok\n' > test/probe_test.rb.expected
printf 'old toolchain\n' > build/.kiln-toolchain
"$root/bin/spin" test > "$scratch/test.log" 2>&1
printf 'ok tests rebuild after a toolchain change\n'

cd "$scratch"
mkdir -p native_probe/ext
cat > native_probe/spin.toml <<'TOML'
[package]
name = "native_probe"
version = "0.0.0"
sources = ["ext/probe.c"]
TOML
cat > native_probe/ext/probe.c <<'C'
const char *kiln_native_cache_probe(void) {
    return KILN_MY_LIBRARY;
}
C
cat > native_probe/native_probe.rb <<'RUBY'
module NativeProbe
  ffi_func :kiln_native_cache_probe, [], :str
end
RUBY
"$root/bin/spin" new native_consumer >/dev/null
cd native_consumer
"$root/bin/spin" add native_probe --path ../native_probe >/dev/null
printf "require 'native_probe'\nputs NativeProbe.kiln_native_cache_probe\n" > bin/native_consumer.rb
unset SPIN_NO_NATIVE_CACHE
SPIN_NATIVE_CACHE="$scratch/native-cache" "$root/bin/spin" build > "$scratch/native-first.log" 2>&1
first=$(build/bin/native_consumer)
find "$scratch/native-cache" -name '*.o' -exec touch -t 203001010000 {} \;
. "$root/ci/native-env.sh"
client_prefix=$("$root/ci/build-mariadb.sh" --check)
cp -R "$client_prefix" "$scratch/other-client"
KILN_MARIADB_PREFIX="$scratch/other-client" SPIN_NATIVE_CACHE="$scratch/native-cache" "$root/bin/spin" build > "$scratch/native-second.log" 2>&1
second=$(build/bin/native_consumer)
expected=$(kiln_mariadb_library "$scratch/other-client")
[ "$first" != "$second" ] && [ "$second" = "$expected" ]
printf 'ok a client change rebuilds native objects with future timestamps\n'
