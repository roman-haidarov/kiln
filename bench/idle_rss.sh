#!/bin/sh
set -eu
server=$1
client=$2
port=$3
count=$4
ulimit -n $((count + 1024))
KILN_MODE=inline PORT=$port SPINEL_WORKERS=1 "$server" >/dev/null 2>&1 &
pid=$!
sleep 1
before=$(ps -o rss= -p "$pid")
fifo=$(mktemp -u)
mkfifo "$fifo"
"$client" "$port" "$count" 8 >"$fifo" &
cpid=$!
read -r line <"$fifo"
sleep "${IDLE_WAIT:-2}"
after=$(ps -o rss= -p "$pid")
wait "$cpid"
kill "$pid"
wait "$pid" 2>/dev/null || true
rm -f "$fifo"
awk -v c="$count" -v b="$before" -v a="$after" -v l="$line" \
  'BEGIN { printf "idle_rss count=%d before_kb=%d after_kb=%d per_conn_kb=%.2f (%s)\n", c, b, a, (a - b) / c, l }'
