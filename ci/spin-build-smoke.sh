#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$root"
spinel_cc=$(pwd)/ci/spinel-cc.sh
export KILN_SPINEL_REAL_CC=${SPINEL_CC:-cc}
spinel=${SPINEL:-spinel}
spinel_path=$(command -v "$spinel")
spinel_dir=$(CDPATH= cd -- "$(dirname -- "$spinel_path")" && pwd -P)
spin=${SPIN:-$spinel_dir/spin}
if [ -n "${SPINEL_REF:-}" ]; then
  actual=$("$spinel" --version | sed -n 's/^[^(]*(\([^)]*\)).*/\1/p')
  case "$SPINEL_REF" in
    "$actual"*) ;;
    *) printf 'Spinel revision mismatch: expected %s, got %s\n' "$SPINEL_REF" "$actual" >&2; exit 1 ;;
  esac
fi
if ! command -v "$spin" >/dev/null 2>&1; then
  printf 'spin executable not found: %s\n' "$spin" >&2
  exit 1
fi
scratch=$(mktemp -d "${TMPDIR:-/tmp}/kiln-spin-install.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
expected=$(sed -n "s/^ *VERSION = '\([^']*\)'.*/\1/p" "$root/kiln/version.rb")
declared=$(sed -n 's/^version = "\([^"]*\)"/\1/p' "$root/spin.toml")
if [ -z "$expected" ] || [ "$expected" != "$declared" ]; then
  printf 'version drift: kiln/version.rb=%s spin.toml=%s\n' "$expected" "$declared" >&2
  exit 1
fi
(cd "$scratch" && "$spin" new kiln_smoke)
cd "$scratch/kiln_smoke"
"$spin" add kiln --path "$root"
cat >bin/kiln_smoke.rb <<'RUBY'
require 'kiln'
json = Kiln::HTTP::Json.generate({ 'x' => 'ё' })
raise 'JSON mismatch' unless json == '{"x":"ё"}'
raise 'version mismatch' unless Kiln::VERSION == ENV.fetch('KILN_EXPECTED_VERSION')
puts 'kiln spin build ok'
RUBY
CC="$spinel_cc" SPIN_NO_NATIVE_CACHE=1 SPIN_NATIVE_CACHE="$scratch/native-cache" "$spin" build
result=$(KILN_EXPECTED_VERSION="$expected" "$scratch/kiln_smoke/build/bin/kiln_smoke")
if [ "$result" != 'kiln spin build ok' ]; then
  printf 'unexpected spin output: %s\n' "$result" >&2
  exit 1
fi
printf '%s\n' "$result"
