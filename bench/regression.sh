#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$root"
spinel_bin=${SPINEL:-spinel}
spinel_cc=$(pwd)/ci/spinel-cc.sh
export KILN_SPINEL_REAL_CC=${SPINEL_CC:-cc}
port=${PORT:-18421}
connections=${CONNECTIONS:-25}
duration=${DURATION:-10}
warmup=${WARMUP:-1}
rounds=${ROUNDS:-3}
selected_modes=${MODES:-"inline lanes server"}
selected_features=${FEATURES:-"text json stream gzip gzip-stream"}
selected_clients=${CLIENTS:-"wrk k6 oha"}
workers=${SPINEL_WORKERS:-1}
sampling=${SAMPLE:-1}
memory=${MEMORY:-0}
sample_interval=${SAMPLE_INTERVAL:-1}
sample_frequency=${SAMPLE_FREQUENCY:-999}
results_root=${RESULTS_DIR:-/tmp/kiln-regression}
stamp=$(date +%Y%m%d-%H%M%S)-$$
results="$results_root/$stamp"
server_pid=
platform=$(uname -s)
server_binary=build/bench/regression_server
sample_extension=sample.txt

case "$sampling:$platform" in
  1:Darwin)
    command -v sample >/dev/null 2>&1 || { printf 'missing required profiler: sample\n' >&2; exit 1; }
    server_binary=build/bench/regression_server_profile
    ;;
  1:Linux)
    command -v perf >/dev/null 2>&1 || { printf 'missing required profiler: perf\n' >&2; exit 1; }
    server_binary=build/bench/regression_server_profile
    sample_extension=perf.data
    ;;
  1:*)
    printf 'sampling is not supported on %s; set SAMPLE=0 to disable it\n' "$platform" >&2
    exit 1
    ;;
  0:*)
    ;;
  *)
    printf 'SAMPLE must be 0 or 1\n' >&2
    exit 1
    ;;
esac

case "$memory" in
  0 | 1)
    ;;
  *)
    printf 'MEMORY must be 0 or 1\n' >&2
    exit 1
    ;;
esac

for tool in $selected_clients; do
  command -v "$tool" >/dev/null 2>&1 || { printf 'missing required tool: %s\n' "$tool" >&2; exit 1; }
done
for tool in curl; do
  command -v "$tool" >/dev/null 2>&1 || { printf 'missing required tool: %s\n' "$tool" >&2; exit 1; }
done

for value in $selected_modes; do
  case "$value" in inline | lanes | server) ;; *) printf 'invalid mode: %s\n' "$value" >&2; exit 1 ;; esac
done
for value in $selected_features; do
  case "$value" in text | json | stream | gzip | gzip-stream) ;; *) printf 'invalid feature: %s\n' "$value" >&2; exit 1 ;; esac
done
for value in $selected_clients; do
  case "$value" in wrk | k6 | oha) ;; *) printf 'invalid client: %s\n' "$value" >&2; exit 1 ;; esac
done

mkdir -p "$results" build/bench
wrk_script="$results/regression.lua"
k6_script="$results/regression_k6.js"
cat >"$wrk_script" <<'LUA'
local failed = false
local route = os.getenv("KILN_ROUTE")
local expected = os.getenv("KILN_EXPECT")

function request()
  local compressed = route == "/gzip" or route == "/gzip-stream"
  local headers = { ["Accept-Encoding"] = compressed and "gzip" or "identity" }
  return wrk.format("GET", route, headers)
end

function response(status, headers, body)
  if status ~= 200 then
    failed = true
    return
  end
  if route == "/gzip" or route == "/gzip-stream" then
    local encoding = nil
    for key, value in pairs(headers) do
      if string.lower(key) == "content-encoding" then encoding = string.lower(value) end
    end
    if encoding ~= "gzip" then failed = true end
  elseif not string.find(body, expected, 1, true) then
    failed = true
  end
end

function done(summary, latency, requests)
  if failed then error("response validation failed for " .. route) end
end
LUA
cat >"$k6_script" <<'JAVASCRIPT'
import http from 'k6/http';
import { check } from 'k6';

const route = __ENV.KILN_ROUTE;
const expected = __ENV.KILN_EXPECT;
const compressed = route === '/gzip' || route === '/gzip-stream';
const encoding = compressed ? 'gzip' : 'identity';

export const options = {
  thresholds: {
    checks: ['rate==1'],
  },
};

export default function () {
  const response = http.get(`${__ENV.KILN_URL}${route}`, {
    headers: { 'Accept-Encoding': encoding },
  });
  check(response, {
    'status is 200': (res) => res.status === 200,
    'body marker is present': (res) => !!res.body && res.body.includes(expected),
    'gzip is applied on compressed routes': (res) => !compressed || res.headers['Content-Encoding'] === 'gzip',
  });
}
JAVASCRIPT
ext_links=$(./ext/build.sh)
if [ "$sampling" -eq 1 ]; then
  "$spinel_bin" "--cc=$spinel_cc" $ext_links --profile -I . bench/regression_server.rb -o "$server_binary"
else
  "$spinel_bin" "--cc=$spinel_cc" $ext_links -I . bench/regression_server.rb -o "$server_binary"
fi

cleanup() {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
    server_pid=
  fi
}
trap cleanup EXIT INT TERM

start_server() {
  mode=$1
  alloc_report="$results/alloc-$mode.current.folded"
  if [ "$memory" -eq 1 ]; then
    KILN_MODE=$mode PORT=$port SPINEL_WORKERS=$workers SPINEL_GC_STATS=1 \
      SPINEL_ALLOC_REPORT="$alloc_report" SPINEL_ALLOC_SITES=1 "./$server_binary" >"$results/server-$mode.log" 2>&1 &
  else
    KILN_MODE=$mode PORT=$port SPINEL_WORKERS=$workers SPINEL_GC_STATS=1 \
      "./$server_binary" >"$results/server-$mode.log" 2>&1 &
  fi
  server_pid=$!
  attempt=0
  while [ "$attempt" -lt 50 ]; do
    if curl -fsS --max-time 1 "http://127.0.0.1:$port/health" >/dev/null 2>&1; then return; fi
    if ! kill -0 "$server_pid" 2>/dev/null; then
      cat "$results/server-$mode.log" >&2
      return 1
    fi
    attempt=$((attempt + 1))
    sleep 0.1
  done
  printf 'server did not start on port %s\n' "$port" >&2
  return 1
}

stop_server() {
  cleanup
  attempt=0
  while curl -fsS --max-time 1 "http://127.0.0.1:$port/health" >/dev/null 2>&1 && [ "$attempt" -lt 20 ]; do
    attempt=$((attempt + 1))
    sleep 0.1
  done
}

run_k6() {
  label=$1
  route=$2
  expected=$3
  seconds=$4
  vus=$5
  KILN_URL="http://127.0.0.1:$port" KILN_ROUTE=$route KILN_EXPECT=$expected \
    k6 run --summary-mode=compact --vus "$vus" --duration "${seconds}s" \
      -e KILN_URL="http://127.0.0.1:$port" -e KILN_ROUTE="$route" -e KILN_EXPECT="$expected" \
      "$k6_script" >"$results/$label.txt" 2>&1 || { cat "$results/$label.txt" >&2; return 1; }
}

run_client() {
  client=$1
  mode=$2
  route=$3
  expected=$4
  round=$5
  client_duration=${6:-$duration}
  route_name=${route#/}
  label="$mode-$route_name-$client-r$round"
  url="http://127.0.0.1:$port$route"
  case "$client" in
    wrk)
      KILN_ROUTE=$route KILN_EXPECT=$expected wrk -t1 -c "$connections" -d "${client_duration}s" \
        --latency -s "$wrk_script" "$url" >"$results/$label.txt" 2>&1
      ;;
    k6)
      run_k6 "$label" "$route" "$expected" "$client_duration" "$connections"
      ;;
    oha)
      encoding=identity
      case "$route" in /gzip | /gzip-stream) encoding=gzip ;; esac
      oha --no-tui --no-color --output-format text -w -c "$connections" -z "${client_duration}s" \
        -H "Accept-Encoding: $encoding" "$url" >"$results/$label.txt" 2>&1 || { cat "$results/$label.txt" >&2; return 1; }
      if ! grep -Eq 'Success rate:[[:space:]]+100\.00%' "$results/$label.txt" || ! grep -Fq '[200]' "$results/$label.txt"; then
        cat "$results/$label.txt" >&2
        return 1
      fi
      ;;
  esac
}

resident_kb() {
  ps -o rss= -p "$server_pid" | awk '{print $1}'
}

cpu_seconds() {
  if [ "$platform" = Linux ]; then
    awk -v hz="$(getconf CLK_TCK)" '{sub(/^.*\) /, ""); print ($12 + $13) / hz}' "/proc/$server_pid/stat"
  else
    ps -o time= -p "$server_pid" | awk -F: '{if (NF == 2) print ($1 * 60) + $2; else if (NF == 3) print ($1 * 3600) + ($2 * 60) + $3; else print ($1 * 86400) + ($2 * 3600) + ($3 * 60) + $4}'
  fi
}

take_alloc_snapshot() {
  output=$1
  previous_mtime=$("$spinel_bin" -E -e 'print(File.file?(ARGV[0]) ? (File.mtime(ARGV[0]).to_r * 1_000_000_000).to_i : 0)' "$alloc_report")
  kill -USR1 "$server_pid"
  "$spinel_bin" -E bench/wait_file_update.rb "$alloc_report" "$previous_mtime"
  cp "$alloc_report" "$output"
}

run_measured_client() {
  client=$1
  mode=$2
  route=$3
  expected=$4
  round=$5
  route_name=${route#/}
  label="$mode-$route_name-$client-r$round"
  sample_file="$results/$label.$sample_extension"
  gc_before="$results/$label.gc.before"
  gc_after="$results/$label.gc.after"
  rss_before="$results/$label.rss.before"
  rss_after="$results/$label.rss.after"
  cpu_before="$results/$label.cpu.before"
  cpu_after="$results/$label.cpu.after"
  grep '^\[gc\]' "$results/server-$mode.log" | tail -1 >"$gc_before" || true
  if [ "$memory" -eq 1 ]; then
    resident_kb >"$rss_before"
    take_alloc_snapshot "$results/$label.alloc.before.folded"
  fi
  cpu_seconds >"$cpu_before"
  run_client "$client" "$mode" "$route" "$expected" "$round" "$duration" &
  client_pid=$!
  if [ "$sampling" -eq 1 ]; then
    if [ "$platform" = Darwin ]; then
      sample "$server_pid" "$duration" "$sample_interval" -file "$sample_file" >"$sample_file.log" 2>&1 &
    else
      perf record -F "$sample_frequency" -g -p "$server_pid" -o "$sample_file" -- sleep "$duration" >"$sample_file.log" 2>&1 &
    fi
    sample_pid=$!
  fi
  client_status=0
  sample_status=0
  wait "$client_pid" || client_status=$?
  if [ "$sampling" -eq 1 ]; then wait "$sample_pid" || sample_status=$?; fi
  if [ "$client_status" -ne 0 ]; then return "$client_status"; fi
  if [ "$sampling" -eq 1 ] && { [ "$sample_status" -ne 0 ] || [ ! -s "$sample_file" ]; }; then
    cat "$sample_file.log" >&2
    printf 'no profiler sample captured for %s\n' "$label" >&2
    return 1
  fi
  cpu_seconds >"$cpu_after"
  grep '^\[gc\]' "$results/server-$mode.log" | tail -1 >"$gc_after" || true
  if [ "$memory" -eq 1 ]; then
    resident_kb >"$rss_after"
    take_alloc_snapshot "$results/$label.alloc.after.folded"
  fi
}

printf 'date=%s\nspinel=%s\nplatform=%s/%s\nworkers=%s\nconnections=%s\nduration=%ss\nwarmup=%ss\nrounds=%s\nsampling=%s\nmemory=%s\nselected_modes=%s\nselected_features=%s\nselected_clients=%s\nsample_interval_ms=%s\nsample_frequency_hz=%s\n' \
  "$stamp" "$spinel_bin" "$platform" "$(uname -m)" "$workers" "$connections" "$duration" "$warmup" "$rounds" "$sampling" "$memory" "$selected_modes" "$selected_features" "$selected_clients" "$sample_interval" "$sample_frequency" >"$results/meta.txt"
for client in $selected_clients; do "$client" --version 2>&1 | head -1 >>"$results/meta.txt" || true; done

for mode in $selected_modes; do
  printf 'mode=%s\n' "$mode"
  start_server "$mode"
  for item in 'text|/text|kiln-regression-text' 'json|/json|kiln-regression-item-0' 'stream|/stream|kiln-regression-text' 'gzip|/gzip|kiln-regression-text' 'gzip-stream|/gzip-stream|kiln-regression-text'; do
    old_ifs=$IFS
    IFS='|'
    set -- $item
    IFS=$old_ifs
    feature=$1
    route=$2
    expected=$3
    case " $selected_features " in *" $feature "*) ;; *) continue ;; esac
    for client in $selected_clients; do
      run_client "$client" "$mode" "$route" "$expected" warm "$warmup"
      round=1
      while [ "$round" -le "$rounds" ]; do
        run_measured_client "$client" "$mode" "$route" "$expected" "$round"
        round=$((round + 1))
      done
      printf '  %-6s %-6s %-6s %s\n' "$feature" "$mode" "$client" "saved"
    done
  done
  stop_server
done

printf 'results=%s\n' "$results"
"$spinel_bin" -E bench/regression_summary.rb "$results" "$memory"
printf 'summary=%s\n' "$results/summary.tsv"
printf 'medians=%s\n' "$results/median.tsv"
