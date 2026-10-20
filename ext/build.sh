#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
cc_bin=${CC:-cc}
flags="${KILN_EXT_CFLAGS:--O2} -DSP_THREADS -DKILN_OPTIMIZED"
compiler_version=$("$cc_bin" --version | sed -n '1p')
hdr_dir=${SPINEL_HDR_DIR:-}
if [ -z "$hdr_dir" ]; then
  spinel_path=$(command -v "${SPINEL:-spinel}" 2> /dev/null || true)
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
content_key=$(find ext -type f \( -name '*.c' -o -name '*.h' -o -name 'build.sh' \) -print | LC_ALL=C sort | xargs $hash_tool | $hash_tool)
runtime_key=$(cd "$hdr_dir" && $hash_tool spinel/runtime.h spinel_rt.h sp_alloc.h sp_gc.h sp_types.h 2> /dev/null | $hash_tool)
build_key=$(printf '%s\n' "$(uname -s)" "$(uname -m)" "$("$cc_bin" -dumpmachine 2> /dev/null || true)" "$cc_bin" "$compiler_version" "$flags" "$hdr_dir" "$content_key" "$runtime_key")
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
for source in ext/picohttpparser/picohttpparser.c ext/kiln_pico_sse42.c ext/kiln_http.c ext/kiln_uv.c ext/kiln_uv_parse.c ext/kiln_tls.c ext/kiln_sock.c ext/kiln_ws.c ext/kiln_json.c ext/kiln_yyjson.c ext/kiln_gzip.c ext/uvsrc/*.c ext/zngsrc/*.c; do
  object=build/ext/$(basename "$source" .c).o
  extra=""
  case "$source" in
    ext/uvsrc/*.c) extra="-Iext/libuv/include -Iext/libuv/src -Iext/libuv/src/unix" ;;
    ext/kiln_uv.c) extra="-Iext/libuv/include" ;;
    ext/zngsrc/*.c) extra="-Iext/zlib-ng $(simd_flags "$source")" ;;
    ext/kiln_http.c | ext/kiln_pico_sse42.c) extra="$(simd_flags "$source")" ;;
  esac
  case "$source" in
    ext/kiln_json.c | ext/kiln_yyjson.c | ext/kiln_gzip.c) extra="-ftls-model=initial-exec -I$hdr_dir" ;;
  esac
  if [ "$rebuild" -eq 1 ] || [ ! -f "$object" ]; then
    "$cc_bin" $flags $extra -c "$source" -o "$object"
  fi
  links="$links --link $object"
done
printf '%s\n' "$build_key" > "$settings"
printf '%s\n' "$links"
