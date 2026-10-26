#!/bin/sh
set -eu

url=${1:-http://127.0.0.1:${PORT:-18200}}
keys=${KEYS:-100000}
script=$(mktemp "${TMPDIR:-/tmp}/kiln-cache-keys.XXXXXX")
trap 'rm -f "$script"' EXIT INT TERM
cat > "$script" <<LUA
local keys = $keys
math.randomseed(1)
request = function()
  local unit = math.random()
  local key = math.floor(unit * unit * unit * keys)
  return wrk.format("GET", "/c/k" .. key)
end
LUA
wrk -s "$script" -t"${WRK_THREADS:-1}" -c"${CONNECTIONS:-32}" -d"${DURATION:-10}s" --latency "$url"
