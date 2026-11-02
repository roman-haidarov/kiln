#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
export KILN_SPINEL_PREFIX=${KILN_SCHEDULER_TEST_PREFIX:-$root/.tools/spinel-test}
export KILN_SPINEL_TEST_HOOKS=1
export KILN_DB=0
"$root/bin/setup"
