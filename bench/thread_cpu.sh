#!/bin/sh
set -eu
pid=$1
seconds=$2
snap() {
  for stat in /proc/"$pid"/task/*/stat; do
    tid=${stat%/stat}
    tid=${tid##*/}
    sed 's/^.*) //' "$stat" | awk -v t="$tid" '{print t, $12 + $13}'
  done
}
before=$(snap)
sleep "$seconds"
after=$(snap)
hz=$(getconf CLK_TCK)
printf '%s\n%s\n' "$before" "$after" | awk -v hz="$hz" -v s="$seconds" '
  seen[$1]++ { printf "thread %s cpu_share %.3f\n", $1, ($2 - first[$1]) / hz / s; next }
  { first[$1] = $2 }' | sort -k4 -g -r
