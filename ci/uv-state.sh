#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
cc_bin=${CC:-cc}
case $(uname -s) in
  Darwin) strip=-Wl,-dead_strip ;;
  *) strip=-Wl,--gc-sections ;;
esac
mkdir -p build/test
"$cc_bin" -std=c11 ${KILN_STATE_CFLAGS:--O2} -Wall -Wextra -Werror -ffunction-sections -fdata-sections -D_GNU_SOURCE -DSP_THREADS \
  -Iext -Iext/libuv/include test/uv_state_test.c ext/kiln_uv_parse.c ext/kiln_http.c "$strip" -pthread -o build/test/uv_state_test
build/test/uv_state_test
