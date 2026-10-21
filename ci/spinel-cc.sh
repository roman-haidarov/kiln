#!/bin/sh
set -eu
set -f

real_cc=${KILN_SPINEL_REAL_CC:-cc}
if $real_cc -dM -E -x c /dev/null 2>/dev/null | grep -q '__clang__'; then
  exec $real_cc -Wno-nullability-completeness "$@"
fi
exec $real_cc "$@"
