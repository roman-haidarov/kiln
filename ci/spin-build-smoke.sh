#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
spinel=${SPINEL:-spinel}
spinel_path=$(command -v "$spinel")
spinel_dir=$(CDPATH= cd -- "$(dirname -- "$spinel_path")" && pwd -P)
spin=${SPIN:-$spinel_dir/spin}
if ! command -v "$spin" >/dev/null 2>&1; then
  printf 'spin executable not found: %s\n' "$spin" >&2
  exit 1
fi
scratch=$(mktemp -d "${TMPDIR:-/tmp}/kiln-spin-install.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
(cd "$scratch" && "$spin" new kiln_smoke)
cd "$scratch/kiln_smoke"
"$spin" add kiln --path "$root"
cat >bin/kiln_smoke.rb <<'RUBY'
require 'kiln'
json = Kiln::Json.generate({ 'x' => 'ё' })
raise 'JSON mismatch' unless json == '{"x":"ё"}'
raise 'version mismatch' unless Kiln::VERSION == '0.0.7'
puts 'kiln spin build ok'
RUBY
SPIN_NO_NATIVE_CACHE=1 SPIN_NATIVE_CACHE="$scratch/native-cache" "$spin" build
result=$("$scratch/kiln_smoke/build/bin/kiln_smoke")
if [ "$result" != 'kiln spin build ok' ]; then
  printf 'unexpected spin output: %s\n' "$result" >&2
  exit 1
fi
printf '%s\n' "$result"
