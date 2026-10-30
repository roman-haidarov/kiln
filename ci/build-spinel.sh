#!/bin/sh
set -eu
umask 022
export LC_ALL=C

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
prefix=${KILN_SPINEL_PREFIX:-$root/.tools/spinel}
case "$prefix" in
  /*) ;;
  *) prefix=$(pwd -P)/$prefix ;;
esac
prefix=${prefix%/}
case "$prefix" in
  ''|/|"$root") printf 'Invalid Spinel installation prefix: %s\n' "$prefix" >&2; exit 1 ;;
esac
ref=$(cat "$root/ci/spinel-ref")
case "$ref" in
  *[!0-9a-f]*|'') printf 'ci/spinel-ref must contain a full commit SHA\n' >&2; exit 1 ;;
esac
[ "${#ref}" -eq 40 ] || { printf 'ci/spinel-ref must contain a full commit SHA\n' >&2; exit 1; }

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

recipe() {
  printf 'format=1\ncommit=%s\nplatform=%s/%s\n' "$ref" "$(uname -s)" "$(uname -m)"
  for input in ci/build-spinel.sh ci/with-build-lock.rb ci/spinel-cc.sh ci/spinel-ref; do
    printf '%s %s\n' "$(sha256 < "$root/$input")" "$input"
  done
  for patch in "$root"/patches/spinel/*.patch; do
    [ -f "$patch" ] || continue
    printf '%s patches/spinel/%s\n' "$(sha256 < "$patch")" "${patch##*/}"
  done
}

payload() {
  for input in lib/spinel/spinel lib/spinel/spin lib/spinel/lib/libspinel_rt.a lib/spinel/lib/libspinel_rt_mt.a lib/spinel/lib/spinel/runtime.h; do
    [ -f "$1/$input" ] || return 1
    printf '%s %s\n' "$(sha256 < "$1/$input")" "$input"
  done
}

matches() {
  [ -x "$1/bin/spinel" ] && [ -x "$1/bin/spin" ] || return 1
  [ -f "$1/share/kiln-spinel/recipe" ] && [ -f "$1/share/kiln-spinel/payload" ] || return 1
  [ "$(readlink "$1/bin/spinel")" = ../lib/spinel/spinel ] || return 1
  [ "$(readlink "$1/bin/spin")" = ../lib/spinel/spin ] || return 1
  [ "$(cat "$1/share/kiln-spinel/recipe")" = "$expected_recipe" ] || return 1
  current_payload=$(payload "$1") || return 1
  [ "$current_payload" = "$(cat "$1/share/kiln-spinel/payload")" ]
}

expected_recipe=$(recipe)

case "${1:-}" in
  --fingerprint) recipe | sha256; exit ;;
  --check)
    if matches "$prefix"; then
      printf '%s\n' "$prefix"
      exit
    fi
    printf 'Spinel installation is missing, stale or damaged: %s\nRun bin/setup to rebuild it.\n' "$prefix" >&2
    exit 1
    ;;
  '') ;;
  *) printf 'Usage: ci/build-spinel.sh [--check|--fingerprint]\n' >&2; exit 2 ;;
esac

if matches "$prefix"; then
  printf '%s\n' "$prefix"
  exit
fi

for tool in git make ruby curl tar cc; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'Missing build prerequisite: %s. See docs/GET_STARTED.md.\n' "$tool" >&2
    exit 1
  }
done

parent=$(dirname -- "$prefix")
mkdir -p "$parent"
parent=$(CDPATH= cd -- "$parent" && pwd -P)
prefix=$parent/${prefix##*/}
lock=$prefix.build-lock
if [ "${KILN_BUILD_LOCK_PATH:-}" != "$lock" ] || ! ruby "$root/ci/with-build-lock.rb" --held "$lock"; then
  exec ruby "$root/ci/with-build-lock.rb" "$lock" "$root/ci/build-spinel.sh" "$@"
fi

work=
cleanup() {
  if [ -n "$work" ]; then
    if [ -e "$work/previous" ] && [ ! -e "$prefix" ]; then
      mv "$work/previous" "$prefix" || return 1
    fi
    rm -rf "$work"
  fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if matches "$prefix"; then
  printf '%s\n' "$prefix"
  exit
fi
if [ -e "$prefix" ] && [ ! -f "$prefix/share/kiln-spinel/recipe" ]; then
  printf 'Refusing to replace an unmanaged installation: %s\nChoose an empty KILN_SPINEL_PREFIX.\n' "$prefix" >&2
  exit 1
fi

work=$(mktemp -d "$parent/.spinel-build.XXXXXX")
source_dir=$work/source
stage=$work/install
printf 'Building Spinel %s with the Kiln patch set\n' "$ref" >&2
git init -q "$source_dir" >&2
git -C "$source_dir" remote add origin https://github.com/matz/spinel.git
git -C "$source_dir" fetch --depth 1 origin "$ref" >&2
git -C "$source_dir" -c advice.detachedHead=false checkout --detach FETCH_HEAD >&2
actual=$(git -C "$source_dir" rev-parse HEAD)
[ "$actual" = "$ref" ] || { printf 'Spinel checkout mismatch: %s\n' "$actual" >&2; exit 1; }
for patch in "$root"/patches/spinel/*.patch; do
  [ -f "$patch" ] || continue
  printf 'Applying %s\n' "${patch##*/}" >&2
  git -C "$source_dir" apply --check "$patch" >&2
  git -C "$source_dir" apply "$patch" >&2
done

spinel_cc=$root/ci/spinel-cc.sh
export KILN_SPINEL_REAL_CC=${SPINEL_CC:-${KILN_SPINEL_REAL_CC:-${CC:-cc}}}
make -C "$source_dir" deps CC="$spinel_cc" >&2
make -C "$source_dir" -j1 CC="$spinel_cc" >&2
make -C "$source_dir" install PREFIX="$stage" CC="$spinel_cc" >&2
for tool in spinel spin spinel-cext-build; do
  ln -sf "../lib/spinel/$tool" "$stage/bin/$tool"
done
mkdir -p "$stage/share/kiln-spinel"
[ "$(recipe)" = "$expected_recipe" ] || { printf 'Toolchain inputs changed during the build; run setup again\n' >&2; exit 1; }
printf '%s\n' "$expected_recipe" > "$stage/share/kiln-spinel/recipe"
payload "$stage" > "$stage/share/kiln-spinel/payload"
matches "$stage" || { printf 'Spinel installation verification failed\n' >&2; exit 1; }
if [ -e "$prefix" ]; then
  mv "$prefix" "$work/previous"
fi
if ! mv "$stage" "$prefix"; then
  [ ! -e "$work/previous" ] || mv "$work/previous" "$prefix"
  exit 1
fi
printf 'Spinel ready: %s\n' "$prefix" >&2
printf '%s\n' "$prefix"
