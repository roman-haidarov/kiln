#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
cc_bin=${KILN_NATIVE_CC:-cc}
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/kiln-uv-embedding.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT
for file in ext/uvsrc/*.c; do
  "$cc_bin" -O2 -std=c11 -pthread -Iext/libuv/include -Iext/libuv/src -Iext/libuv/src/unix -c "$file" -o "$build_dir/$(basename "$file" .c).o"
done
for name in kiln_uv kiln_uv_parse kiln_http kiln_tls kiln_sock; do
  "$cc_bin" -O2 -std=c11 -pthread -DSP_THREADS -Iext -Iext/libuv/include -c "ext/$name.c" -o "$build_dir/$name.o"
done
"$cc_bin" -O2 -std=c11 -pthread -c ext/picohttpparser/picohttpparser.c -o "$build_dir/picohttpparser.o"
"$cc_bin" -O2 -std=c11 -pthread -Iext -Iext/libuv/include bench/libuv_embedding_test.c "$build_dir"/*.o -ldl -o "$build_dir/test"
"$build_dir/test"
