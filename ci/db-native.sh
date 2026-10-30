#!/usr/bin/env bash
set -eu
set -o pipefail

cd "$(dirname "$0")/.."
cc_bin=${CC:-cc}
mode=${1:-}

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

object_names() {
  line=$(awk '/^for source in /{print; exit}' ext/build.sh)
  list=${line#for source in }
  list=${list%; do}
  db_sources=$(printf '%s ' ext/db/*.c ext/kiln_db_wait.c)
  eval "set -- $list"
  for source in "$@"; do
    basename "$source" .c
  done
}

check_objects() {
  seen=$(mktemp -d "${TMPDIR:-/tmp}/kiln-db-objs.XXXXXX")
  trap 'rm -rf "$seen"' EXIT
  object_names | while IFS= read -r name; do
    if [ -e "$seen/$name" ]; then
      printf 'duplicate object %s.o\n' "$name" >&2
      exit 1
    fi
    : > "$seen/$name"
  done
}

libpq_prefix=${KILN_DB_LIBPQ_PREFIX:-/opt/homebrew/opt/libpq}
mariadb_prefix=${KILN_DB_LIBMARIADB_PREFIX:-$(./ci/build-mariadb.sh)}
db_includes="-I ext/db -I${libpq_prefix}/include -I${mariadb_prefix}/include/mariadb"

build_uv() {
  KILN_DB=1 ./ext/build.sh >/dev/null
}

unit() {
  check_objects
  out=$(mktemp -d "${TMPDIR:-/tmp}/kiln-db-unit.XXXXXX")
  for source in ext/db/*.c ext/kiln_db_wait.c; do
    "$cc_bin" -std=c11 -Wall -Wextra -Werror -O2 -DSP_THREADS -DKILN_OPTIMIZED $db_includes \
      -c "$source" -o "$out/$(basename "$source" .c).o"
  done
  rm -rf "$out"
  printf 'ok native unit\n'
}

asan() {
  check_objects
  build_uv
  out=$(mktemp -d "${TMPDIR:-/tmp}/kiln-db-asan.XXXXXX")
  for source in ext/db/*.c; do
    "$cc_bin" -std=c11 -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer \
      -DSP_THREADS -DKILN_OPTIMIZED $db_includes \
      -c "$source" -o "$out/$(basename "$source" .c).o"
  done
  "$cc_bin" -std=c11 -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer \
    -DSP_THREADS $db_includes test/db/support/kiln_db_asan.c "$out"/*.o build/ext/uv_*.o -pthread -ldl \
    -o "$out/asan"
  "$out/asan"
  rm -rf "$out"
}

affinity() {
  build_uv
  out=$(mktemp -d "${TMPDIR:-/tmp}/kiln-db-affinity.XXXXXX")
  for source in ext/db/*.c; do
    "$cc_bin" -std=c11 -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer \
      -DSP_THREADS -DKILN_OPTIMIZED $db_includes \
      -c "$source" -o "$out/$(basename "$source" .c).o"
  done
  "$cc_bin" -std=c11 -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer \
    -DSP_THREADS $db_includes test/db/support/kiln_db_affinity.c "$out"/*.o build/ext/uv_*.o -pthread -ldl \
    -o "$out/affinity"
  "$out/affinity"
  rm -rf "$out"
}

safety() {
  out=$(mktemp -d "${TMPDIR:-/tmp}/kiln-db-safety.XXXXXX")
  "$cc_bin" -std=c11 -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer \
    -DSP_THREADS -Iext/db test/db/support/kiln_db_slot_lifetime.c ext/db/kiln_db_arena.c \
    -pthread -o "$out/slot"
  "$out/slot"
  "$cc_bin" -std=c11 -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer \
    -DSP_THREADS -Iext/db test/db/support/kiln_db_core_lifetime.c ext/db/kiln_db_arena.c \
    ext/db/kiln_db_core.c -pthread -o "$out/core"
  "$out/core"
  "$cc_bin" -std=c11 -Wall -Wextra -Werror -O1 -g -fsanitize=thread -fno-omit-frame-pointer \
    -DSP_THREADS -Iext/db bench/db_pin_stress.c ext/db/kiln_db_arena.c -pthread -o "$out/pin_tsan"
  "$out/pin_tsan" 2
  "$cc_bin" -std=c11 -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer \
    -DSP_THREADS -Iext/db bench/db_pin_stress.c ext/db/kiln_db_arena.c -pthread -o "$out/pin_asan"
  "$out/pin_asan" 2
  "$cc_bin" -std=c11 -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer \
    -DSP_THREADS -Iext/db test/db/support/kiln_db_null_words.c -o "$out/words"
  "$out/words"
  printf 'ok null words\n'
  rm -rf "$out"
}

dns() {
  build_uv
  out=$(mktemp -d "${TMPDIR:-/tmp}/kiln-db-dns.XXXXXX")
  for source in ext/db/*.c; do
    "$cc_bin" -std=c11 -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer \
      -DSP_THREADS -DKILN_OPTIMIZED $db_includes \
      -c "$source" -o "$out/$(basename "$source" .c).o"
  done
  "$cc_bin" -std=c11 -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer \
    -DSP_THREADS $db_includes test/db/support/kiln_db_dns_uv.c "$out"/*.o build/ext/uv_*.o -pthread -ldl \
    -o "$out/dns"
  "$out/dns"
  rm -rf "$out"
}

case "$mode" in
  unit) unit ;;
  asan) asan ;;
  affinity) affinity ;;
  safety) safety ;;
  dns) dns ;;
  *)
    printf 'usage: ci/db-native.sh unit|asan|affinity|safety|dns\n' >&2
    exit 2
    ;;
esac
