#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
runtime="$root/build/db-runtime"
envfile="$runtime/session.env"
cmd=${1:-}

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

load_project() {
  [ -f "$envfile" ] || fail "audit refused: no session manifest"
  KILN_DB_PROJECT=$(awk -F= '$1=="KILN_DB_PROJECT"{print $2; exit}' "$envfile")
  [ -n "$KILN_DB_PROJECT" ] || fail "audit refused: project id missing"
  case "$KILN_DB_PROJECT" in
    kilndb_[0-9a-f]*) ;;
    *) fail "audit refused: project id shape" ;;
  esac
}

project_containers() {
  docker ps -aq --no-trunc --filter "label=com.docker.compose.project=$KILN_DB_PROJECT"
}

project_networks() {
  docker network ls -q --filter "label=com.docker.compose.project=$KILN_DB_PROJECT"
}

project_volumes() {
  docker volume ls -q --filter "label=com.docker.compose.project=$KILN_DB_PROJECT"
}

count_lines() {
  if [ -z "$1" ]; then
    printf '0\n'
  else
    printf '%s\n' "$1" | wc -l | awk '{print $1}'
  fi
}

verify_running() {
  load_project
  ids=$(project_containers | sort)
  n=$(count_lines "$ids")
  [ "$n" = "4" ] || fail "verify-running: container count $n"
  nets=$(project_networks)
  nn=$(count_lines "$nets")
  [ "$nn" = "1" ] || fail "verify-running: network count $nn"
  vols=$(project_volumes)
  vn=$(count_lines "$vols")
  [ "$vn" = "4" ] || fail "verify-running: volume count $vn"
  [ -f "$runtime/startup_count" ] || fail "verify-running: startup_count missing"
  sc=$(cat "$runtime/startup_count")
  [ "$sc" = "1" ] || fail "verify-running: startup_count=$sc"
  [ -f "$runtime/container-ids.txt" ] || fail "verify-running: saved ids missing"
  current="$runtime/container-ids.current"
  printf '%s\n' "$ids" > "$current"
  cmp -s "$runtime/container-ids.txt" "$current" || fail "verify-running: container ids changed"
  for id in $ids; do
    health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$id")
    [ "$health" = "healthy" ] || fail "verify-running: health $health"
    state=$(docker inspect -f '{{.State.Status}}' "$id")
    [ "$state" = "running" ] || fail "verify-running: state $state"
    bindings=$(docker inspect -f '{{json .HostConfig.PortBindings}}' "$id")
    printf '%s\n' "$bindings" | grep -q '0.0.0.0' && fail "verify-running: published on 0.0.0.0"
    printf '%s\n' "$bindings" | grep -q '127.0.0.1' || fail "verify-running: missing loopback bind"
    privileged=$(docker inspect -f '{{.HostConfig.Privileged}}' "$id")
    [ "$privileged" = "false" ] || fail "verify-running: privileged"
    netmode=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$id")
    [ "$netmode" != "host" ] || fail "verify-running: host network"
  done
  printf 'verify-running PASS\n'
  printf 'startup_count=%s\n' "$sc"
  printf 'project_count=1\n'
  printf 'DOCKER_PROJECT_ID=%s\n' "$KILN_DB_PROJECT"
}

verify_clean() {
  load_project
  ids=$(project_containers)
  n=$(count_lines "$ids")
  nets=$(project_networks)
  nn=$(count_lines "$nets")
  vols=$(project_volumes)
  vn=$(count_lines "$vols")
  [ "$n" = "0" ] || fail "verify-clean: containers left $n"
  [ "$nn" = "0" ] || fail "verify-clean: networks left $nn"
  [ "$vn" = "0" ] || fail "verify-clean: volumes left $vn"
  owned=0
  if [ -f "$runtime/images-owned.txt" ]; then
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      if docker image inspect "$id" >/dev/null 2>&1; then
        owned=$((owned + 1))
      fi
    done < "$runtime/images-owned.txt"
  fi
  [ "$owned" = "0" ] || fail "verify-clean: owned images left $owned"
  printf 'verify-clean PASS\n'
  printf 'cleanup_verified=PASS\n'
  printf 'project_owned_resources_after_cleanup=0\n'
  printf 'DOCKER_PROJECT_ID=%s\n' "$KILN_DB_PROJECT"
}

case "$cmd" in
  verify-running) verify_running ;;
  verify-clean) verify_clean ;;
  *)
    printf 'usage: ci/db-docker-audit.sh verify-running|verify-clean\n' >&2
    exit 2
    ;;
esac
