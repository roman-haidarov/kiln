#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
. ./ci/native-env.sh
cc_bin=${CC:-cc}
flags="${KILN_EXT_CFLAGS:--O2} -DSP_THREADS -DKILN_OPTIMIZED"
compiler_version=$("$cc_bin" --version | sed -n '1p')
hdr_dir=${SPINEL_HDR_DIR:-}
if [ -z "$hdr_dir" ]; then
  spinel_bin=${SPINEL:-}
  if [ -z "$spinel_bin" ]; then
    prefix=$(./ci/build-spinel.sh)
    spinel_bin=$prefix/bin/spinel
  fi
  spinel_path=$(command -v "$spinel_bin" 2> /dev/null || true)
  if [ -n "$spinel_path" ]; then
    spinel_dir=$(cd "$(dirname "$spinel_path")" && pwd -P)
    if [ -L "$spinel_path" ]; then
      link=$(readlink "$spinel_path")
      case "$link" in
        /*) spinel_dir=$(cd "$(dirname "$link")" && pwd -P) ;;
        *) spinel_dir=$(cd "$spinel_dir/$(dirname "$link")" && pwd -P) ;;
      esac
    fi
    for candidate in "$spinel_dir/lib" "$spinel_dir/../lib" "$spinel_dir/../lib/spinel/lib"; do
      if [ -f "$candidate/spinel_rt.h" ]; then
        hdr_dir=$(cd "$candidate" && pwd -P)
        break
      fi
    done
  fi
fi
if [ -z "$hdr_dir" ] || [ ! -f "$hdr_dir/spinel/runtime.h" ]; then
  printf 'kiln: Spinel runtime headers not found; set SPINEL or SPINEL_HDR_DIR\n' >&2
  exit 1
fi
if command -v sha256sum > /dev/null 2>&1; then
  hash_tool="sha256sum"
elif command -v shasum > /dev/null 2>&1; then
  hash_tool="shasum -a 256"
else
  hash_tool="cksum"
fi
content_key=$(find ext -path ext/croaring -prune -o -type f \( -name '*.c' -o -name '*.h' -o -name 'build.sh' \) -print | LC_ALL=C sort | xargs $hash_tool | $hash_tool)
db_sources=""
db_flags=""
db_key=""
db_enabled=${KILN_DB:-1}
mariadb_library=
if [ "$db_enabled" = "1" ]; then
  if [ -n "${KILN_DB_LIBPQ_PREFIX:-}" ]; then
    pq_flags="-I$KILN_DB_LIBPQ_PREFIX/include"
  elif pkg-config --exists libpq 2> /dev/null; then
    pq_flags=$(pkg-config --cflags libpq)
  elif [ -d /opt/homebrew/opt/libpq/include ]; then
    pq_flags="-I/opt/homebrew/opt/libpq/include"
  else
    pq_flags=""
  fi
  if [ -z "${KILN_DB_LIBMARIADB_PREFIX:-}" ]; then
    KILN_DB_LIBMARIADB_PREFIX=$(./ci/build-mariadb.sh)
  fi
  mariadb_library=$(kiln_mariadb_library "$KILN_DB_LIBMARIADB_PREFIX")
  my_flags="-I$KILN_DB_LIBMARIADB_PREFIX/include/mariadb"
  db_flags="$pq_flags $my_flags"
  db_key=$(find "$KILN_DB_LIBMARIADB_PREFIX/include" -type f | LC_ALL=C sort | while IFS= read -r header; do $hash_tool "$header"; done | $hash_tool)
  db_sources=$(printf '%s ' ext/db/*.c ext/kiln_db_wait.c)
fi
runtime_key=$(cd "$hdr_dir" && $hash_tool spinel/runtime.h spinel_rt.h sp_alloc.h sp_gc.h sp_types.h 2> /dev/null | $hash_tool)
build_key=$(printf '%s\n' "$(uname -s)" "$(uname -m)" "$("$cc_bin" -dumpmachine 2> /dev/null || true)" "$cc_bin" "$compiler_version" "$flags" "$hdr_dir" "$db_enabled" "$db_flags" "$db_key" "$mariadb_library" "$content_key" "$runtime_key")
target=$("$cc_bin" -dumpmachine 2> /dev/null || uname -m)
simd_flags() {
  case "$target" in
    x86_64* | amd64*)
      case "$1" in
        *_x86_features.c) printf '%s' "-mxsave" ;;
        *_ssse3.c) printf '%s' "-mssse3" ;;
        *_sse41.c) printf '%s' "-msse4.1" ;;
        *_sse42.c) printf '%s' "-msse4.2" ;;
        */kiln_http.c) printf '%s' "-DKILN_PICO_SSE42" ;;
        *_pclmulqdq.c) printf '%s' "-msse4.2 -mpclmul" ;;
        *_avx2.c) printf '%s' "-mavx2 -mbmi -mbmi2" ;;
      esac
      ;;
    aarch64* | arm64*)
      case "$1" in
        *_armv8.c) printf '%s' "-march=armv8-a+crc" ;;
        *_pmull_eor3.c) printf '%s' "-march=armv8.2-a+crc+crypto+sha3" ;;
        *_neon.c) printf '%s' "-march=armv8-a+simd" ;;
      esac
      ;;
  esac
}
mkdir -p build/ext
links=""
rebuild=0
settings=build/ext/settings
if [ ! -f "$settings" ] || [ "$(cat "$settings")" != "$build_key" ]; then
  rebuild=1
fi
for source in ext/picohttpparser/picohttpparser.c ext/kiln_pico_sse42.c ext/kiln_http.c ext/kiln_uv.c ext/kiln_uv_parse.c ext/kiln_tls.c ext/kiln_sock.c ext/kiln_ws.c ext/kiln_json.c ext/kiln_yyjson.c ext/kiln_gzip.c ext/kiln_cache.c ext/uvsrc/*.c ext/zngsrc/*.c $db_sources; do
  object=build/ext/$(basename "$source" .c).o
  extra=""
  case "$source" in
    ext/uvsrc/*.c) extra="-Iext/libuv/include -Iext/libuv/src -Iext/libuv/src/unix" ;;
    ext/kiln_uv.c) extra="-Iext/libuv/include" ;;
    ext/zngsrc/*.c) extra="-Iext/zlib-ng $(simd_flags "$source")" ;;
    ext/kiln_http.c | ext/kiln_pico_sse42.c) extra="$(simd_flags "$source")" ;;
    ext/db/*.c) extra="$db_flags" ;;
  esac
  case "$source" in
    ext/kiln_json.c | ext/kiln_yyjson.c | ext/kiln_gzip.c) extra="-ftls-model=initial-exec -I$hdr_dir" ;;
  esac
  if [ "$rebuild" -eq 1 ] || [ ! -f "$object" ]; then
    if [ "$source" = ext/db/kiln_db_my.c ]; then
      "$cc_bin" $flags $extra "-DKILN_MY_LIBRARY=\"$mariadb_library\"" -c "$source" -o "$object"
    else
      "$cc_bin" $flags $extra -c "$source" -o "$object"
    fi
  fi
  links="$links --link $object"
done
printf '%s\n' "$build_key" > "$settings"
printf '%s\n' "$links"
