#!/bin/sh
set -eu
results_dir=${KILN_VALIDATION_DIR:-/tmp/kiln-validation}
mkdir -p "$results_dir"
exec gprofng collect app -O "$results_dir/server-profile.er" build/stress_server
