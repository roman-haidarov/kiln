#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
cc_bin=${CC:-cc}
flags=${KILN_ADMISSION_CFLAGS:--O2}
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/kiln-admission.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT
for source in ext/uvsrc/*.c ext/kiln_uv_parse.c ext/kiln_http.c ext/kiln_tls.c ext/kiln_sock.c ext/picohttpparser/picohttpparser.c; do
  "$cc_bin" $flags -std=c11 -D_GNU_SOURCE -DSP_THREADS -pthread \
    -Iext -Iext/libuv/include -Iext/libuv/src -Iext/libuv/src/unix \
    -c "$source" -o "$build_dir/$(basename "$source" .c).o"
done
"$cc_bin" $flags -std=c11 -DSP_THREADS -pthread -Iext -Iext/libuv/include \
  test/admission_test.c "$build_dir"/*.o -ldl -o "$build_dir/test"
"$build_dir/test"
