#!/bin/sh
set -eu
umask 022
export LC_ALL=C
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
prefix=${KILN_MARIADB_PREFIX:-$root/.tools/mariadb}
case "$prefix" in
  /*) ;;
  *) prefix=$(pwd -P)/$prefix ;;
esac
prefix=${prefix%/}
case "$prefix" in
  ''|/|"$root") printf 'Invalid Connector/C installation prefix: %s\n' "$prefix" >&2; exit 1 ;;
esac
ref=$(cat "$root/ci/mariadb-ref")
archive_hash=$(cat "$root/ci/mariadb-source.sha256")
case "$ref:$archive_hash" in
  *[!0-9a-f:]*|:*) printf 'Invalid Connector/C source pin\n' >&2; exit 1 ;;
esac
[ "${#ref}" -eq 40 ] && [ "${#archive_hash}" -eq 64 ] || exit 1
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}
recipe() {
  printf 'format=1\ncommit=%s\narchive=%s\nplatform=%s/%s\n' "$ref" "$archive_hash" "$(uname -s)" "$(uname -m)"
  for input in ci/build-mariadb.sh ci/with-build-lock.rb ci/mariadb-ref ci/mariadb-source.sha256; do
    printf '%s %s\n' "$(sha256 < "$root/$input")" "$input"
  done
}
library() {
  case "$(uname -s)" in
    Darwin) printf '%s/lib/mariadb/libmariadb.dylib\n' "$1" ;;
    *) printf '%s/lib/mariadb/libmariadb.so\n' "$1" ;;
  esac
}
payload() {
  shared=$(library "$1")
  [ -f "$shared" ] && [ -f "$1/include/mariadb/mariadb_version.h" ] || return 1
  printf '%s library\n' "$(sha256 < "$shared")"
  printf '%s headers\n' "$(cd "$1" && find include -type f | LC_ALL=C sort | while IFS= read -r header; do printf '%s %s\n' "$(sha256 < "$header")" "$header"; done | sha256)"
}
matches() {
  [ -f "$1/share/kiln-mariadb/recipe" ] && [ -f "$1/share/kiln-mariadb/payload" ] || return 1
  [ "$(cat "$1/share/kiln-mariadb/recipe")" = "$expected_recipe" ] || return 1
  current_payload=$(payload "$1") || return 1
  [ "$current_payload" = "$(cat "$1/share/kiln-mariadb/payload")" ]
}
expected_recipe=$(recipe)
case "${1:-}" in
  --fingerprint) recipe | sha256; exit ;;
  --check)
    if matches "$prefix"; then printf '%s\n' "$prefix"; exit; fi
    printf 'Connector/C installation is missing, stale or damaged: %s\nRun bin/setup to rebuild it.\n' "$prefix" >&2
    exit 1 ;;
  '') ;;
  *) printf 'Usage: ci/build-mariadb.sh [--check|--fingerprint]\n' >&2; exit 2 ;;
esac
if matches "$prefix"; then printf '%s\n' "$prefix"; exit; fi
for tool in cmake curl tar cc ruby; do
  command -v "$tool" >/dev/null 2>&1 || { printf 'Missing build prerequisite: %s. See docs/GET_STARTED.md.\n' "$tool" >&2; exit 1; }
done
parent=$(dirname -- "$prefix")
mkdir -p "$parent"
parent=$(CDPATH= cd -- "$parent" && pwd -P)
prefix=$parent/${prefix##*/}
lock=$prefix.build-lock
if [ "${KILN_BUILD_LOCK_PATH:-}" != "$lock" ] || ! ruby "$root/ci/with-build-lock.rb" --held "$lock"; then
  exec ruby "$root/ci/with-build-lock.rb" "$lock" "$root/ci/build-mariadb.sh" "$@"
fi

work=
cleanup() {
  if [ -n "$work" ]; then
    if [ -e "$work/previous" ] && [ ! -e "$prefix" ]; then mv "$work/previous" "$prefix"; fi
    rm -rf "$work"
  fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
if matches "$prefix"; then printf '%s\n' "$prefix"; exit; fi
if [ -e "$prefix" ] && [ ! -f "$prefix/share/kiln-mariadb/recipe" ]; then
  printf 'Refusing to replace an unmanaged installation: %s\n' "$prefix" >&2
  exit 1
fi
work=$(mktemp -d "$parent/.mariadb-build.XXXXXX")
printf 'Building MariaDB Connector/C %s\n' "$ref" >&2
curl --fail --location --retry 3 --output "$work/source.tar.gz" "https://codeload.github.com/mariadb-corporation/mariadb-connector-c/tar.gz/$ref" >&2
[ "$(sha256 < "$work/source.tar.gz")" = "$archive_hash" ] || { printf 'Connector/C archive checksum mismatch\n' >&2; exit 1; }
mkdir "$work/source"
tar -xzf "$work/source.tar.gz" --strip-components=1 -C "$work/source"
set -- -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" -DINSTALL_LIBDIR=lib/mariadb -DWITH_SSL=OPENSSL -DWITH_UNIT_TESTS=OFF -DWITH_CURL=OFF
if [ "$(uname -s)" = Darwin ] && command -v brew >/dev/null 2>&1; then
  set -- "$@" "-DOPENSSL_ROOT_DIR=$(brew --prefix openssl@3)"
fi
cmake -S "$work/source" -B "$work/build" "$@" >&2
cmake --build "$work/build" --parallel 2 >&2
DESTDIR="$work/stage" cmake --install "$work/build" >&2
stage=$work/stage$prefix
mkdir -p "$stage/share/kiln-mariadb"
[ "$(recipe)" = "$expected_recipe" ] || { printf 'Connector/C inputs changed during the build\n' >&2; exit 1; }
printf '%s\n' "$expected_recipe" > "$stage/share/kiln-mariadb/recipe"
payload "$stage" > "$stage/share/kiln-mariadb/payload"
matches "$stage" || { printf 'Connector/C verification failed\n' >&2; exit 1; }
if [ -e "$prefix" ]; then mv "$prefix" "$work/previous"; fi
mv "$stage" "$prefix"
printf '%s\n' "$prefix"
