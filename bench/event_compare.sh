#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
spinel_bin=${SPINEL:-spinel}
spinel_cc=$(pwd)/ci/spinel-cc.sh
export KILN_SPINEL_REAL_CC=${SPINEL_CC:-cc}
rounds=${ROUNDS:-3}
conns=${CONNS:-50}
seconds=${SECONDS_PER_RUN:-10}
port=${PORT:-18100}
command -v wrk > /dev/null 2>&1 || { printf 'wrk is required: install it and rerun\n' >&2; exit 1; }
mkdir -p build/bench
ext_links=$(./ext/build.sh)
"$spinel_bin" "--cc=$spinel_cc" $ext_links -I . bench/hello_modes.rb -o build/bench/hello_modes > /dev/null

cpu_ticks() {
  if [ -r "/proc/$1/stat" ]; then
    awk '{print $14 + $15}' "/proc/$1/stat"
  else
    ps -o time= -p "$1" | awk -F'[:.]' '{print (($1 * 60) + $2) * 100 + $3}'
  fi
}

one() {
  KILN_MODE=$1 PORT=$port SPINEL_WORKERS=1 build/bench/hello_modes > /dev/null 2>&1 &
  pid=$!
  sleep 1
  wrk -t1 -c"$conns" -d2s "http://127.0.0.1:$port/" > /dev/null 2>&1 || true
  c0=$(cpu_ticks "$pid")
  out=$(wrk -t1 -c"$conns" -d"${seconds}s" --latency "http://127.0.0.1:$port/" 2>&1 || true)
  c1=$(cpu_ticks "$pid")
  kill "$pid" 2> /dev/null || true
  wait "$pid" 2> /dev/null || true
  reqs=$(printf '%s\n' "$out" | awk '/requests in/ {print $1}')
  if [ -z "$reqs" ] || [ "$reqs" -eq 0 ]; then
    printf 'no requests completed for mode %s:\n%s\n' "$1" "$out" >&2
    exit 1
  fi
  rps=$(printf '%s\n' "$out" | awk '/Requests\/sec/ {print $2}')
  p99=$(printf '%s\n' "$out" | awk '$1 == "99%" {print $2}')
  ticks=$((c1 - c0))
  printf '%-7s rps=%s p99=%s cpu_us_per_request=%s\n' "$1" "${rps:-0}" "${p99:-na}" \
    "$(awk -v t="$ticks" -v r="${reqs:-1}" -v hz=100 'BEGIN {printf "%.2f", t / hz / r * 1e6}')"
}

i=0
while [ "$i" -lt "$rounds" ]; do
  case $((i % 3)) in
    0) order="server inline lanes" ;;
    1) order="lanes server inline" ;;
    *) order="inline lanes server" ;;
  esac
  for mode in $order; do
    one "$mode"
  done
  i=$((i + 1))
done
