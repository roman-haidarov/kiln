#!/bin/sh
set -eu

base=${1:?usage: bench/matrix.sh BASE_SERVER NEW_SERVER}
new=${2:?usage: bench/matrix.sh BASE_SERVER NEW_SERVER}
runs=${RUNS:-3}
seconds=${SECONDS_PER_RUN:-5}
warmup=${WARMUP:-1}
workers_list=${WORKERS_LIST:-"1 2"}
conns_list=${CONNS_LIST:-"32"}
routes=${ROUTES:-"/health /big"}
depths=${PIPELINE_LIST:-"1"}
wrk_threads=${WRK_THREADS:-2}
max_minutes=${MAX_MINUTES:-10}
port=${PORT:-19400}
results_dir=${KILN_VALIDATION_DIR:-/tmp/kiln-validation}/bench
out=${OUT:-$results_dir/matrix.txt}

count() { set -- $1; echo $#; }
points=$(( $(count "$workers_list") * $(count "$conns_list") * $(count "$routes") * $(count "$depths") ))
estimate=$(( points * runs * 2 * (seconds + warmup + 3) / 60 + 1 ))
printf 'matrix: %s points x %s runs x 2 builds, ~%s min (limit %s)\n' "$points" "$runs" "$estimate" "$max_minutes"
if [ "$estimate" -gt "$max_minutes" ] && [ "${FORCE:-0}" != 1 ]; then
  printf 'refusing: estimate exceeds MAX_MINUTES; reduce the grid or set FORCE=1\n' >&2
  exit 2
fi

mkdir -p "$(dirname "$out")"
: > "$out"
lua=$(dirname "$out")/pipeline.lua

cpu_ticks() {
  if [ -r "/proc/$1/stat" ]; then
    awk '{print $14 + $15}' "/proc/$1/stat"
  else
    ps -o time= -p "$1" | awk -F: '{print (($1 * 60) + $2) * 100}'
  fi
}

one() {
  label=$1; bin=$2; workers=$3; conns=$4; route=$5; depth=$6
  SPINEL_WORKERS=$workers PORT=$port "$bin" $((seconds + warmup + 4)) > /dev/null 2>&1 &
  pid=$!
  sleep 1
  script=""
  if [ "$depth" -gt 1 ]; then
    printf 'init = function(args)\n  local r = {}\n  for i = 1, %s do r[i] = wrk.format(nil, "%s") end\n  req = table.concat(r)\nend\nrequest = function() return req end\n' "$depth" "$route" > "$lua"
    script="-s $lua"
  fi
  wrk -t"$wrk_threads" -c"$conns" -d"${warmup}s" $script "http://127.0.0.1:$port$route" > /dev/null 2>&1 || true
  c0=$(cpu_ticks "$pid")
  res=$(wrk -t"$wrk_threads" -c"$conns" -d"${seconds}s" --latency $script "http://127.0.0.1:$port$route" 2>&1 || true)
  c1=$(cpu_ticks "$pid")
  kill "$pid" 2> /dev/null || true
  wait "$pid" 2> /dev/null || true
  reqs=$(printf '%s\n' "$res" | awk '/requests in/ {print $1}')
  errs=$(printf '%s\n' "$res" | awk '/Socket errors|Non-2xx/ {n++} END {print n + 0}')
  p50=$(printf '%s\n' "$res" | awk '$1 == "50%" {print $2}')
  p99=$(printf '%s\n' "$res" | awk '$1 == "99%" {print $2}')
  printf '%s workers=%s conns=%s route=%s depth=%s requests=%s errors=%s p50=%s p99=%s cpu_ticks=%s\n' \
    "$label" "$workers" "$conns" "$route" "$depth" "${reqs:-0}" "$errs" "${p50:-na}" "${p99:-na}" "$((c1 - c0))" >> "$out"
}

for workers in $workers_list; do
  for conns in $conns_list; do
    for route in $routes; do
      for depth in $depths; do
        i=0
        while [ "$i" -lt "$runs" ]; do
          if [ $((i % 2)) -eq 0 ]; then
            one base "$base" "$workers" "$conns" "$route" "$depth"
            one new "$new" "$workers" "$conns" "$route" "$depth"
          else
            one new "$new" "$workers" "$conns" "$route" "$depth"
            one base "$base" "$workers" "$conns" "$route" "$depth"
          fi
          i=$((i + 1))
        done
      done
    done
  done
done

printf '%-7s %-5s %-8s %-5s %-5s %10s %10s %10s %6s\n' workers conns route depth build cpu_us_med rps_med p99_last bad
awk -v hz="$(getconf CLK_TCK)" -v secs="$seconds" '
  {
    for (f = 2; f <= NF; f++) { split($f, kv, "="); v[kv[1]] = kv[2] }
    key = v["workers"] " " v["conns"] " " v["route"] " " v["depth"] " " $1
    seen[key] = 1
    if (v["errors"] > 0 || v["requests"] == 0) { bad[key]++; next }
    n[key]++
    cpu[key, n[key]] = v["cpu_ticks"] / hz / v["requests"] * 1e6
    rps[key, n[key]] = v["requests"] / secs
    p99[key] = v["p99"]
    seen[key] = 1
  }
  function med(arr, key, m,    i, j, x, a) {
    for (i = 1; i <= m; i++) a[i] = arr[key, i]
    for (i = 2; i <= m; i++) { x = a[i]; j = i - 1; while (j >= 1 && a[j] > x) { a[j + 1] = a[j]; j-- } a[j + 1] = x }
    return (m % 2) ? a[(m + 1) / 2] : (a[m / 2] + a[m / 2 + 1]) / 2
  }
  END {
    for (key in seen) {
      split(key, k, " ")
      if (n[key] > 0) {
        printf "%-7s %-5s %-8s %-5s %-5s %10.1f %10.0f %10s %6d\n", k[1], k[2], k[3], k[4], k[5], med(cpu, key, n[key]), med(rps, key, n[key]), p99[key], bad[key]
      } else {
        printf "%-7s %-5s %-8s %-5s %-5s %10s %10s %10s %6d\n", k[1], k[2], k[3], k[4], k[5], "n/a", "n/a", "n/a", bad[key]
      }
    }
  }' "$out" | sort
