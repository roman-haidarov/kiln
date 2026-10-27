#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cc_bin=${KILN_NATIVE_CC:-clang}
revision=${KILN_TSAN_OPENSSL_REV:-45e844fa2a14ec92d146bd8f5778ac130b6625fb} # OpenSSL 3.5.9
jobs=${KILN_TSAN_OPENSSL_JOBS:-2}
base=${KILN_TSAN_OPENSSL_CACHE:-$root/build/openssl-tsan}
link_flags=${KILN_NATIVE_LDFLAGS:-}

fail() {
  printf 'OpenSSL TSan: %s\n' "$1" >&2
  exit 1
}

case $(uname -s) in
  Linux) ssl_name=libssl.so.3; crypto_name=libcrypto.so.3 ;;
  Darwin) ssl_name=libssl.3.dylib; crypto_name=libcrypto.3.dylib ;;
  *) fail 'only Linux and macOS are supported by this CI helper' ;;
esac

verify_libs() {
  for name in "$ssl_name" "$crypto_name"; do
    [ -f "$1/$name" ] || fail "missing $1/$name"
    nm -g "$1/$name" 2>/dev/null | grep -q '__tsan_' ||
      fail "$1/$name was not built with ThreadSanitizer"
  done
}

if [ -n "${KILN_TSAN_OPENSSL_LIBDIR:-}" ]; then
  libdir=$(CDPATH= cd -- "$KILN_TSAN_OPENSSL_LIBDIR" && pwd)
  verify_libs "$libdir"
  printf '%s\n' "$libdir"
  exit 0
fi

case "$revision" in ''|*[!0-9a-f]*) fail 'revision must be a full immutable Git commit' ;; esac
[ "${#revision}" -eq 40 ] || fail 'revision must contain 40 hexadecimal digits'
case "$jobs" in ''|*[!0-9]*|0) fail 'build job count must be positive' ;; esac
command -v "$cc_bin" >/dev/null 2>&1 || fail "compiler not found: $cc_bin"
command -v git >/dev/null 2>&1 || fail 'git is required'
command -v perl >/dev/null 2>&1 || fail 'perl is required'

digest() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum
  else
    shasum -a 256
  fi
}

signature=$(printf '%s\n' "$revision" "$cc_bin" "$("$cc_bin" --version)" \
  "$(uname -sm)" "$link_flags" 'shared no-tests no-apps no-docs -O1 -g -fsanitize=thread -fno-omit-frame-pointer' |
  digest | awk '{print $1}')
mkdir -p "$base"
base=$(CDPATH= cd -- "$base" && pwd)
cache="$base/$signature"
prefix="$cache/install"
libdir="$prefix/lib"
record_build() {
  {
    printf 'OpenSSL source: %s\n' "$revision"
    printf 'Compiler: %s\n' "$cc_bin"
    "$cc_bin" --version
    printf 'CFLAGS: -O1 -g -fsanitize=thread -fno-omit-frame-pointer\n'
    printf 'LDFLAGS: -fsanitize=thread %s\n' "$link_flags"
  } > "$prefix/build-info.txt"
}
if [ -f "$cache/complete" ] && [ "$(cat "$cache/complete")" = "$signature" ]; then
  verify_libs "$libdir"
  record_build
  printf '%s\n' "$libdir"
  exit 0
fi

mkdir -p "$cache"
lock="$cache/build.lock"
mkdir "$lock" 2>/dev/null || fail "build already in progress: $cache"
log="$cache/build.log"
cleanup() {
  status=$?
  if [ "$status" -ne 0 ]; then
    tail -60 "$log" >&2
    printf 'OpenSSL TSan: build failed; full log: %s\n' "$log" >&2
  fi
  rmdir "$lock" 2>/dev/null || true
  exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
source="$cache/source"
build="$cache/build"
printf 'OpenSSL TSan: building %s with %s (log: %s)\n' "$revision" "$cc_bin" "$log" >&2
(
  if [ ! -d "$source/.git" ]; then
    mkdir -p "$source"
    git -C "$source" init -q
    git -C "$source" remote add origin https://github.com/openssl/openssl.git
  fi
  if ! git -C "$source" cat-file -e "$revision^{commit}" 2>/dev/null; then
    git -C "$source" fetch --depth 1 origin "$revision"
  fi
  git -C "$source" checkout --detach "$revision"
  [ "$(git -C "$source" rev-parse HEAD)" = "$revision" ]
  git -C "$source" diff --quiet
  mkdir -p "$build"
  cd "$build"
  CC="$cc_bin" CFLAGS='-O1 -g -fsanitize=thread -fno-omit-frame-pointer' \
    LDFLAGS="-fsanitize=thread $link_flags" \
    perl "$source/Configure" shared no-tests no-apps no-docs --prefix="$prefix" --libdir=lib
  make -j"$jobs" build_libs
  make install_runtime_libs
) > "$log" 2>&1
verify_libs "$libdir"
record_build
printf '%s\n' "$signature" > "$cache/complete"
printf '%s\n' "$libdir"
