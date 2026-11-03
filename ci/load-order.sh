#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
spinel_bin=${SPINEL:-$(./ci/build-spinel.sh)/bin/spinel}
spinel_cc=$(pwd)/ci/spinel-cc.sh
export KILN_SPINEL_REAL_CC=${SPINEL_CC:-cc}
. ./ci/test-process.sh
results=${KILN_VALIDATION_DIR:-/tmp/kiln-validation}/load-order
mkdir -p build/test/load-order "$results"
ext_links=$(./ext/build.sh)

for variant in require-only boot db-boot constant-lambda native-single native-threaded; do
  source=build/test/load-order/$variant.rb
  binary=build/test/load-order/$variant
  expected=$results/$variant.expected
  result=$results/$variant.out
  case "$variant" in
    require-only)
      printf "require 'kiln'\n" > "$source"
      : > "$expected"
      ;;
    boot)
      printf "puts :boot\nrequire 'kiln'\nputs :loaded\n" > "$source"
      printf 'boot\nloaded\n' > "$expected"
      ;;
    db-boot)
      printf "puts :boot\nrequire 'kiln/db'\nrequire 'kiln'\nputs :loaded\n" > "$source"
      printf 'boot\nloaded\n' > "$expected"
      ;;
    constant-lambda)
      cat > "$source" <<'RUBY'
module BootConfig
  CALLBACK = -> { 'boot' }
end
puts BootConfig::CALLBACK.call
require 'kiln'
require 'kiln/db'
puts :loaded
RUBY
      printf 'boot\nloaded\n' > "$expected"
      ;;
    native-single)
      printf "require 'kiln'\nputs Kiln::HTTP::Json.generate({ 'ready' => true })\n" > "$source"
      printf '{"ready":true}\n' > "$expected"
      ;;
    native-threaded)
      cat > "$source" <<'RUBY'
require 'kiln'
out = Queue.new
worker = Thread.new { out << Kiln::HTTP::Json.generate({ 'ready' => true }) }
puts out.pop
worker.join
RUBY
      printf '{"ready":true}\n' > "$expected"
      ;;
  esac
  "$spinel_bin" "--cc=$spinel_cc" $ext_links -I . "$source" -o "$binary"
  run_test_process "$binary" "$result" "${TEST_TIMEOUT:-40}"
  if [ "$status" -ne 0 ]; then
    cat "$result" >&2
    printf 'FAIL load order %s: exit %s\n' "$variant" "$status" >&2
    exit 1
  fi
  diff -u "$expected" "$result"
  printf 'ok   load order %s\n' "$variant"
done
