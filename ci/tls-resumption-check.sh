#!/bin/sh
set -eu
port=$1
loops=$2
scratch=$(mktemp -d "${TMPDIR:-/tmp}/kiln-tls-resume.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
request='GET /resume HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n'
openssl s_client -connect "127.0.0.1:$port" -tls1_2 -sess_out "$scratch/session" </dev/null >/dev/null 2>&1
[ -s "$scratch/session" ] || { printf 'no TLS 1.2 session issued\n'; exit 1; }
batch=$((loops * 4))
[ "$batch" -le 64 ] || batch=64
target=$loops
[ "$target" -le 2 ] || target=2
round=0
while [ "$round" -lt 12 ]; do
  index=0
  while [ "$index" -lt "$batch" ]; do
    (printf "$request" | openssl s_client -ign_eof -tls1_2 -connect "127.0.0.1:$port" \
      -sess_in "$scratch/session" >"$scratch/out.$round.$index" 2>&1) &
    index=$((index + 1))
  done
  wait
  for out in "$scratch"/out.$round.*; do
    grep -q '^Reused, TLSv1.2' "$out" || { printf 'session not resumed\n'; exit 1; }
    lane=$(grep -a -o 'lane=[0-9]*' "$out" | head -n 1 | cut -d= -f2)
    [ -n "$lane" ] && [ "$lane" -lt "$loops" ] || { printf 'no loop id in response\n'; exit 1; }
    : >"$scratch/lane.$lane"
  done
  seen=$(find "$scratch" -name 'lane.*' | wc -l | tr -d ' ')
  [ "$seen" -lt "$target" ] || { printf 'ok TLS session resumption on tested event loops\n'; exit 0; }
  round=$((round + 1))
done
printf 'resumption covered %s/%s required loops\n' "$seen" "$target"
exit 1
