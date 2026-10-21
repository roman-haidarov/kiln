#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
runtime="$root/build/db-runtime"
envfile="$runtime/session.env"
config="$runtime/config"
lock="$root/ci/db-versions.lock"
compose_file="$root/ci/db-compose.yml"
start_timeout=${KILN_DB_START_TIMEOUT:-300}
pq_prefix=${KILN_DB_LIBPQ_PREFIX:-/opt/homebrew/opt/libpq}
my_prefix=${KILN_DB_LIBMARIADB_PREFIX:-/opt/homebrew/opt/mariadb-connector-c}

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

compose_cmd() {
  docker compose -p "$KILN_DB_PROJECT" -f "$compose_file" --env-file "$envfile" "$@"
}

load_env() {
  [ -f "$envfile" ] || fail "session manifest missing"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|\#*) continue ;;
    esac
    key=${line%%=*}
    val=${line#*=}
    case "$key" in
      ''|*[!A-Za-z0-9_]*) fail "bad session key" ;;
    esac
    export "$key=$val"
  done < "$envfile"
  [ -n "${KILN_DB_PROJECT:-}" ] || fail "project id missing"
}

count_lines() {
  if [ -z "$1" ]; then
    printf '0\n'
  else
    printf '%s\n' "$1" | wc -l | awk '{print $1}'
  fi
}

project_ids() {
  docker ps -aq --no-trunc --filter "label=com.docker.compose.project=$KILN_DB_PROJECT" | sort
}

require_tools() {
  command -v docker >/dev/null 2>&1 || fail "BLOCKED: docker missing"
  docker compose version >/dev/null 2>&1 || fail "BLOCKED: docker compose missing"
  command -v openssl >/dev/null 2>&1 || fail "BLOCKED: openssl missing"
}

snapshot_inventory() {
  dest=$1
  mkdir -p "$dest"
  docker ps -a --no-trunc --format '{{.ID}}\t{{.Names}}\t{{.Image}}' > "$dest/ps.txt"
  docker network ls --no-trunc --format '{{.ID}}\t{{.Name}}' > "$dest/net.txt"
  docker volume ls --format '{{.Name}}' > "$dest/vol.txt"
  docker images --no-trunc --format '{{.ID}}\t{{.Repository}}\t{{.Tag}}' > "$dest/images.txt"
  docker images -q --no-trunc | sort -u > "$dest/image-ids.txt"
}

lock_value() {
  key=$1
  awk -F= -v k="$key" '$1==k {print substr($0, index($0, "=")+1); exit}' "$lock"
}

remember_owned_image() {
  ref=$1
  id=$(docker image inspect --format '{{.Id}}' "$ref")
  arch=$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$ref")
  digests=$(docker image inspect --format '{{json .RepoDigests}}' "$ref")
  [ "$arch" = "$(lock_value platform)" ] || fail "image arch $arch for $ref"
  digest=${ref##*@}
  printf '%s\n' "$digests" | grep -q "$digest" || fail "pulled digest missing from RepoDigests"
  if [ -f "$runtime/inventory-before/image-ids.txt" ] && grep -F -x "$id" "$runtime/inventory-before/image-ids.txt" >/dev/null 2>&1; then
    printf 'image_preexisting id_kept %s\n' "$id"
    return 0
  fi
  mkdir -p "$runtime"
  touch "$runtime/images-owned.txt"
  if ! grep -F -x "$id" "$runtime/images-owned.txt" >/dev/null 2>&1; then
    printf '%s\n' "$id" >> "$runtime/images-owned.txt"
  fi
}

pull_locked() {
  [ -s "$lock" ] || fail "BLOCKED: ci/db-versions.lock missing; pin image digests before up"
  platform=$(lock_value platform)
  case "$platform" in
    linux/amd64|linux/arm64) ;;
    *) fail "BLOCKED: unsupported or missing locked Docker platform" ;;
  esac
  [ "$(lock_value image_digests_confirmed)" = "1" ] || fail "BLOCKED: image digests not confirmed"
  for key in postgres_17 postgres_18 mysql_8_4 mariadb_11_4; do
    image=$(lock_value "image_$key")
    case "$image" in
      docker.io/library/*@sha256:*) ;;
      *) fail "BLOCKED: invalid image reference for $key" ;;
    esac
    digest=${image##*@sha256:}
    [ "${#digest}" -eq 64 ] && [[ "$digest" =~ ^[a-f0-9]{64}$ ]] || fail "BLOCKED: invalid digest for $key"
    docker pull --platform "$platform" "$image" >/dev/null || fail "BLOCKED: cannot fetch pinned $key digest for $platform"
    remember_owned_image "$image"
  done
  printf 'DIGESTS_LOCKED\n'
}

measure_clients() {
  if grep -q '^libpq_pqlibversion=' "$lock"; then
    return 0
  fi
  cat > "$runtime/client_ver.c" <<'EOF'
#include <stdio.h>
#include <libpq-fe.h>
#include <mysql.h>
int main(void) {
    printf("%d\n", PQlibVersion());
    printf("%lu\n", mysql_get_client_version());
    return 0;
}
EOF
  cc -std=c11 -I"$pq_prefix/include" -I"$my_prefix/include/mariadb" "$runtime/client_ver.c" \
    -L"$pq_prefix/lib" -L"$my_prefix/lib" -lpq -lmariadb -o "$runtime/client_ver"
  ver=$("$runtime/client_ver")
  pqv=$(printf '%s\n' "$ver" | awk 'NR==1{print}')
  myv=$(printf '%s\n' "$ver" | awk 'NR==2{print}')
  umask 022
  printf 'libpq_prefix=%s\n' "$pq_prefix" >> "$lock"
  printf 'libpq_pqlibversion=%s\n' "$pqv" >> "$lock"
  printf 'mariadb_connector_c_prefix=%s\n' "$my_prefix" >> "$lock"
  printf 'mariadb_connector_c_packed=%s\n' "$myv" >> "$lock"
  umask 077
  printf 'client_libpq=%s\n' "$pqv"
  printf 'client_mariadb=%s\n' "$myv"
}

write_tls() {
  mkdir -p "$config"
  cp "$root/ci/db-pg-entry.sh" "$config/pg-entry.sh"
  cp "$root/ci/db-my-entry.sh" "$config/my-entry.sh"
  cp "$root/ci/db-maria-entry.sh" "$config/maria-entry.sh"
  cp "$root/ci/db-mysql-init.sh" "$config/mysql-init.sh"
  chmod 644 "$config"/*.sh
  if [ -f "$config/ca.crt" ] && [ -f "$config/server.crt" ] && [ -f "$config/server.key" ]; then
    return 0
  fi
  openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 825 \
    -keyout "$config/ca.key" -out "$config/ca.crt" -subj "/CN=kiln-db-ci-ca" >/dev/null
  openssl req -newkey rsa:2048 -nodes -sha256 \
    -keyout "$config/server.key" -out "$config/server.csr" -subj "/CN=localhost" >/dev/null
  cat > "$config/san.cnf" <<'EOF'
basicConstraints=CA:FALSE
subjectAltName=DNS:localhost,DNS:pg17,DNS:pg18,DNS:mysql84,DNS:mariadb114,IP:127.0.0.1
extendedKeyUsage=serverAuth
keyUsage=digitalSignature,keyEncipherment
EOF
  openssl x509 -req -in "$config/server.csr" -CA "$config/ca.crt" -CAkey "$config/ca.key" \
    -CAcreateserial -out "$config/server.crt" -days 825 -sha256 -extfile "$config/san.cnf" >/dev/null
  openssl verify -CAfile "$config/ca.crt" "$config/server.crt" >/dev/null
  chmod 600 "$config/ca.key" "$config/server.key" "$config/server.csr"
  chmod 644 "$config/ca.crt" "$config/server.crt" "$config"/*.sh
  rm -f "$config/server.csr"
}

write_session() {
  sid=$(openssl rand -hex 6)
  project="kilndb_$sid"
  pg_pass=$(openssl rand -hex 24)
  my_pass=$(openssl rand -hex 24)
  root_pass=$(openssl rand -hex 24)
  umask 077
  : > "$envfile"
  chmod 600 "$envfile"
  cat >> "$envfile" <<EOF
KILN_DB_PROJECT=$project
KILN_DB_SESSION=$sid
KILN_DB_START_TIMEOUT=$start_timeout
KILN_DB_CONFIG_DIR=$config
KILN_DB_IMAGE_PG17=$(lock_value image_postgres_17)
KILN_DB_IMAGE_PG18=$(lock_value image_postgres_18)
KILN_DB_IMAGE_MYSQL84=$(lock_value image_mysql_8_4)
KILN_DB_IMAGE_MARIADB114=$(lock_value image_mariadb_11_4)
KILN_DB_PG_USER=kiln
KILN_DB_PG_PASSWORD=$pg_pass
KILN_DB_PG_DB=kilndb
KILN_DB_MY_USER=kiln
KILN_DB_MY_PASSWORD=$my_pass
KILN_DB_MY_DB=kilndb
KILN_DB_MY_ROOT_PASSWORD=$root_pass
KILN_DB_TLS_NAME=localhost
EOF
  KILN_DB_PROJECT=$project
}

record_ports() {
  tmp="$runtime/session.env.next"
  awk -F= '$1 !~ /^DB_/' "$envfile" > "$tmp"
  mv "$tmp" "$envfile"
  chmod 600 "$envfile"
  port_of() {
    service=$1
    line=$(compose_cmd port "$service" "$2")
    printf '%s\n' "$line" | grep -q '^127.0.0.1:' || fail "port for $service is not loopback: $line"
    printf '%s\n' "$line" | awk -F: '{print $2}'
  }
  pg17=$(port_of pg17 5432)
  pg18=$(port_of pg18 5432)
  my=$(port_of mysql84 3306)
  maria=$(port_of mariadb114 3306)
  cat >> "$envfile" <<EOF
DB_PG17_HOST=127.0.0.1
DB_PG17_PORT=$pg17
DB_PG18_HOST=127.0.0.1
DB_PG18_PORT=$pg18
DB_MY_HOST=127.0.0.1
DB_MY_PORT=$my
DB_MARIA_HOST=127.0.0.1
DB_MARIA_PORT=$maria
EOF
  pg_user=$(awk -F= '$1=="KILN_DB_PG_USER"{print $2; exit}' "$envfile")
  pg_pass=$(awk -F= '$1=="KILN_DB_PG_PASSWORD"{print $2; exit}' "$envfile")
  pg_db=$(awk -F= '$1=="KILN_DB_PG_DB"{print $2; exit}' "$envfile")
  my_user=$(awk -F= '$1=="KILN_DB_MY_USER"{print $2; exit}' "$envfile")
  my_pass=$(awk -F= '$1=="KILN_DB_MY_PASSWORD"{print $2; exit}' "$envfile")
  my_db=$(awk -F= '$1=="KILN_DB_MY_DB"{print $2; exit}' "$envfile")
  ca="$config/ca.crt"
  cat >> "$envfile" <<EOF
DB_PG17_URL=postgresql://$pg_user:$pg_pass@127.0.0.1:$pg17/$pg_db?sslmode=verify-full&sslrootcert=$ca
DB_PG18_URL=postgresql://$pg_user:$pg_pass@127.0.0.1:$pg18/$pg_db?sslmode=verify-full&sslrootcert=$ca
DB_MY_URL=mysql://$my_user:$my_pass@127.0.0.1:$my/$my_db
DB_MARIA_URL=mysql://$my_user:$my_pass@127.0.0.1:$maria/$my_db
EOF
  printf 'ports_loopback pg17=%s pg18=%s mysql84=%s mariadb114=%s\n' "$pg17" "$pg18" "$my" "$maria"
}

compile_probe() {
  cc -std=c11 -Wall -Wextra -I"$pq_prefix/include" -I"$my_prefix/include/mariadb" \
    "$root/ci/db-host-probe.c" -L"$pq_prefix/lib" -L"$my_prefix/lib" -lpq -lmariadb \
    -Wl,-rpath,"$pq_prefix/lib" -Wl,-rpath,"$my_prefix/lib" \
    -o "$runtime/host-probe"
}

run_probe() {
  mode=$1
  host=$2
  port=$3
  user=$4
  pass=$5
  db=$6
  tls_name=$7
  KILN_DB_PROBE_MODE="$mode" \
    KILN_DB_PROBE_HOST="$host" \
    KILN_DB_PROBE_PORT="$port" \
    KILN_DB_PROBE_USER="$user" \
    KILN_DB_PROBE_PASSWORD="$pass" \
    KILN_DB_PROBE_DB="$db" \
    KILN_DB_PROBE_CA="$config/ca.crt" \
    KILN_DB_PROBE_TLS_NAME="$tls_name" \
    KILN_DB_PROBE_TIMEOUT=15 \
    "$runtime/host-probe"
}

sql_exec_pg() {
  service=$1
  compose_cmd exec -T "$service" psql -q -v ON_ERROR_STOP=1 -U "$KILN_DB_PG_USER" -d "$KILN_DB_PG_DB" -At
}

sql_exec_my() {
  service=$1
  client=$2
  case "$client" in
    mysql|mariadb) ;;
    *) fail "bad mysql client" ;;
  esac
  compose_cmd exec -T "$service" sh -c "$client"' --protocol=socket -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE" -N' 2>>"$runtime/client-stderr.txt"
}

assert_tx_pg() {
  service=$1
  out=$(printf '%s\n' \
    "DROP TABLE IF EXISTS kiln_db_tx_probe;" \
    "CREATE TABLE kiln_db_tx_probe(id int);" \
    "BEGIN;" \
    "INSERT INTO kiln_db_tx_probe(id) VALUES (1);" \
    "ROLLBACK;" \
    "SELECT COUNT(*) FROM kiln_db_tx_probe;" \
    "DROP TABLE kiln_db_tx_probe;" \
    | sql_exec_pg "$service")
  count=$(printf '%s\n' "$out" | awk 'NF{last=$0} END{print last}')
  [ "$count" = "0" ] || fail "$service rollback left rows: $count"
  printf '%s_tx=0\n' "$service"
}

assert_tx_my() {
  service=$1
  client=$2
  out=$(printf '%s\n' \
    "DROP TABLE IF EXISTS kiln_db_tx_probe;" \
    "CREATE TABLE kiln_db_tx_probe(id int);" \
    "START TRANSACTION;" \
    "INSERT INTO kiln_db_tx_probe(id) VALUES (1);" \
    "ROLLBACK;" \
    "SELECT COUNT(*) FROM kiln_db_tx_probe;" \
    "DROP TABLE kiln_db_tx_probe;" \
    | sql_exec_my "$service" "$client")
  count=$(printf '%s\n' "$out" | awk 'NF{last=$0} END{print last}')
  [ "$count" = "0" ] || fail "$service rollback left rows: $count"
  printf '%s_tx=0\n' "$service"
}

status_cmd() {
  load_env
  compile_probe
  proof="$runtime/sql-proof.txt"
  : > "$proof"
  chmod 600 "$proof"
  pg17v=$(run_probe pg 127.0.0.1 "$DB_PG17_PORT" "$KILN_DB_PG_USER" "$KILN_DB_PG_PASSWORD" "$KILN_DB_PG_DB" "$KILN_DB_TLS_NAME")
  pg18v=$(run_probe pg 127.0.0.1 "$DB_PG18_PORT" "$KILN_DB_PG_USER" "$KILN_DB_PG_PASSWORD" "$KILN_DB_PG_DB" "$KILN_DB_TLS_NAME")
  myv=$(run_probe my 127.0.0.1 "$DB_MY_PORT" "$KILN_DB_MY_USER" "$KILN_DB_MY_PASSWORD" "$KILN_DB_MY_DB" "$KILN_DB_TLS_NAME")
  mariav=$(run_probe my 127.0.0.1 "$DB_MARIA_PORT" "$KILN_DB_MY_USER" "$KILN_DB_MY_PASSWORD" "$KILN_DB_MY_DB" "$KILN_DB_TLS_NAME")
  printf '%s\n' "$pg17v" "$pg18v" "$myv" "$mariav" | tee -a "$proof"
  enc17=$(printf 'SHOW server_encoding;' | sql_exec_pg pg17)
  enc18=$(printf 'SHOW server_encoding;' | sql_exec_pg pg18)
  myset=$(printf 'SELECT @@character_set_server, @@collation_server;' | sql_exec_my mysql84 mysql)
  maset=$(printf 'SELECT @@character_set_server, @@collation_server;' | sql_exec_my mariadb114 mariadb)
  plugin=$(compose_cmd exec -T mysql84 sh -c 'mysql --protocol=socket -uroot -p"$MYSQL_ROOT_PASSWORD" -N -e "SELECT plugin FROM mysql.user WHERE user=\"${MYSQL_USER}\""' 2>>"$runtime/client-stderr.txt")
  if [ "$plugin" != "caching_sha2_password" ]; then
    compose_cmd exec -T mysql84 sh -c 'mysql --protocol=socket -uroot -p"$MYSQL_ROOT_PASSWORD" -e "ALTER USER \"${MYSQL_USER}\"@\"%\" IDENTIFIED WITH caching_sha2_password BY \"${MYSQL_PASSWORD}\""' 2>>"$runtime/client-stderr.txt"
    plugin=$(compose_cmd exec -T mysql84 sh -c 'mysql --protocol=socket -uroot -p"$MYSQL_ROOT_PASSWORD" -N -e "SELECT plugin FROM mysql.user WHERE user=\"${MYSQL_USER}\""' 2>>"$runtime/client-stderr.txt")
  fi
  mariaplugin=$(compose_cmd exec -T mariadb114 sh -c 'mariadb --protocol=socket -uroot -p"$MYSQL_ROOT_PASSWORD" -N -e "SELECT plugin FROM mysql.user WHERE user=\"${MYSQL_USER}\""' 2>>"$runtime/client-stderr.txt")
  printf 'pg17_encoding=%s\n' "$enc17" | tee -a "$proof"
  printf 'pg18_encoding=%s\n' "$enc18" | tee -a "$proof"
  printf 'mysql84_charset=%s\n' "$myset" | tee -a "$proof"
  printf 'mariadb114_charset=%s\n' "$maset" | tee -a "$proof"
  printf 'mysql84_plugin=%s\n' "$plugin" | tee -a "$proof"
  printf 'mariadb114_plugin=%s\n' "$mariaplugin" | tee -a "$proof"
  [ "$plugin" = "caching_sha2_password" ] || fail "mysql plugin is $plugin"
  assert_tx_pg pg17 | tee -a "$proof"
  assert_tx_pg pg18 | tee -a "$proof"
  assert_tx_my mysql84 mysql | tee -a "$proof"
  assert_tx_my mariadb114 mariadb | tee -a "$proof"
  [ "$enc17" = "UTF8" ] || fail "pg17 encoding mismatch"
  [ "$enc18" = "UTF8" ] || fail "pg18 encoding mismatch"
  printf '%s\n' "$myset" | grep -q 'utf8mb4' || fail "mysql charset mismatch"
  printf '%s\n' "$maset" | grep -q 'utf8mb4' || fail "mariadb charset mismatch"
  printf '%s\n' "$pg17v" | grep -q 'PostgreSQL 17' || fail "pg17 version mismatch"
  printf '%s\n' "$pg18v" | grep -q 'PostgreSQL 18' || fail "pg18 version mismatch"
  printf '%s\n' "$myv" | grep -q 'my_version=8.4' || fail "mysql version mismatch"
  printf '%s\n' "$mariav" | grep -q 'my_version=11.4' || fail "mariadb version mismatch"
  printf 'versions_verified=4/4\n'
  printf 'REAL_SQL_PROOF=%s\n' "$proof"
  printf 'DOCKER_PROJECT_ID=%s\n' "$KILN_DB_PROJECT"
}

healthy_same() {
  ids=$(project_ids)
  n=$(count_lines "$ids")
  [ "$n" = "4" ] || return 1
  printf '%s\n' "$ids" > "$runtime/container-ids.current"
  cmp -s "$runtime/container-ids.txt" "$runtime/container-ids.current" || return 1
  for id in $ids; do
    health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$id")
    [ "$health" = "healthy" ] || return 1
  done
  return 0
}

up_cmd() {
  require_tools
  umask 077
  mkdir -p "$runtime"
  chmod 700 "$runtime"
  if [ -f "$envfile" ] && [ -f "$runtime/startup_count" ]; then
    load_env
    if healthy_same; then
      printf 'REUSED\n'
      printf 'startup_count=1\n'
      printf 'DOCKER_PROJECT_ID=%s\n' "$KILN_DB_PROJECT"
      return 0
    fi
    fail "existing project is not healthy; refusing a new project id"
  fi
  if [ ! -f "$envfile" ]; then
    if [ ! -d "$runtime/inventory-before" ]; then
      snapshot_inventory "$runtime/inventory-before"
    fi
    printf 'PREFLIGHT_OK\n'
    pull_locked
    measure_clients
    write_tls
    write_session
  else
    load_env
    write_tls
  fi
  if ! compose_cmd up -d --wait --pull never; then
    compose_cmd logs --tail 120 2>&1 | grep -v -i -e password -e identified > "$runtime/up-fail.log" || true
    fail "compose up failed; redacted log $runtime/up-fail.log"
  fi
  printf 'UP_STARTED\n'
  record_ports
  load_env
  ids=$(project_ids)
  printf '%s\n' "$ids" > "$runtime/container-ids.txt"
  status_cmd
  printf '1\n' > "$runtime/startup_count"
  printf 'startup_count=1\n'
  printf 'DOCKER_HEALTH=healthy\n'
}

env_cmd() {
  load_env
  printf 'DB_ENV_FILE=%s\n' "$envfile"
  printf 'DB_PG17_HOST=%s\n' "$DB_PG17_HOST"
  printf 'DB_PG17_PORT=%s\n' "$DB_PG17_PORT"
  printf 'DB_PG18_HOST=%s\n' "$DB_PG18_HOST"
  printf 'DB_PG18_PORT=%s\n' "$DB_PG18_PORT"
  printf 'DB_MY_HOST=%s\n' "$DB_MY_HOST"
  printf 'DB_MY_PORT=%s\n' "$DB_MY_PORT"
  printf 'DB_MARIA_HOST=%s\n' "$DB_MARIA_HOST"
  printf 'DB_MARIA_PORT=%s\n' "$DB_MARIA_PORT"
  printf 'DB_PG17_URL_VAR=DB_PG17_URL\n'
  printf 'DB_PG18_URL_VAR=DB_PG18_URL\n'
  printf 'DB_MY_URL_VAR=DB_MY_URL\n'
  printf 'DB_MARIA_URL_VAR=DB_MARIA_URL\n'
}

image_in_use() {
  id=$1
  cids=$(docker ps -aq)
  for cid in $cids; do
    iid=$(docker inspect -f '{{.Image}}' "$cid")
    if [ "$iid" = "$id" ]; then
      return 0
    fi
  done
  return 1
}

down_cmd() {
  [ -f "$envfile" ] || fail "down refused: no session manifest"
  load_env
  compose_cmd down --volumes --remove-orphans
  if [ -f "$runtime/images-owned.txt" ]; then
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      if image_in_use "$id"; then
        printf 'image_kept_in_use %s\n' "$id"
        continue
      fi
      docker rmi "$id" >/dev/null
      printf 'image_removed %s\n' "$id"
    done < "$runtime/images-owned.txt"
    : > "$runtime/images-owned.txt"
  fi
  sh "$root/ci/db-docker-audit.sh" verify-clean
}

cmd=${1:-}
case "$cmd" in
  up) up_cmd ;;
  status) status_cmd ;;
  env) env_cmd ;;
  down) down_cmd ;;
  *)
    printf 'usage: ci/db-services.sh up|status|env|down\n' >&2
    exit 2
    ;;
esac
