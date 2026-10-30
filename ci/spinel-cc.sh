#!/bin/sh
set -eu
set -f

real_cc=${KILN_SPINEL_REAL_CC:-cc}
if [ -n "${KILN_MARIADB_LIBRARY:-}" ]; then
  set -- "-DKILN_MY_LIBRARY=\"$KILN_MARIADB_LIBRARY\"" "$@"
fi
if $real_cc -dM -E -x c /dev/null 2>/dev/null | grep -q '__clang__'; then
  exec $real_cc -Wno-nullability-completeness "$@"
fi
exec $real_cc "$@"
