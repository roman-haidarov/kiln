#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
spinel_bin=${SPINEL:-/tmp/spinel-d12-prefix/bin/spinel}
export SPINEL="$spinel_bin"
out=${KILN_GATE_B_DIR:-/tmp/kiln-gate-b-run}
gate_iters=${KILN_GATE_B_ITERS:-2000}
mkdir -p "$out"
rm -f build/ext/kiln_db_*.o
links=$(KILN_DB=1 ./ext/build.sh)
"$spinel_bin" $links -I . bench/db/gate_b.rb -o "$out/gate_b"
export SPINEL_WORKERS=1
KILN_GATE_B_ITERS=$gate_iters /usr/bin/time -l -o "$out/time-all.txt" "$out/gate_b" > "$out/all.out" 2>"$out/all.err"
for round in 1 2 3; do
  case "$round" in
    1) set -- copy block ;;
    2) set -- block copy ;;
    3) set -- copy block ;;
  esac
  for path do
    KILN_GATE_B_ITERS=$gate_iters KILN_GATE_B_PATH=$path SPINEL_ALLOC_REPORT="$out/alloc-$round-$path.txt" \
      /usr/bin/time -l -o "$out/time-$round-$path.txt" "$out/gate_b" > "$out/$round-$path.out" \
      2>"$out/$round-$path.err"
  done
done
KILN_GATE_B_ITERS=$gate_iters "$out/gate_b" > "$out/sample-run.out" 2>"$out/sample-run.err" &
pid=$!
sleep 0.4
sample "$pid" 5 -file "$out/sample.txt" > "$out/sample-tool.out" 2>&1 || true
wait "$pid"
printf 'gate-b logs %s\n' "$out"
