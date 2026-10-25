#!/bin/sh
set -eu
cp /kiln-config/server.crt /tmp/kiln-server.crt
cp /kiln-config/server.key /tmp/kiln-server.key
cp /kiln-config/ca.crt /tmp/kiln-ca.crt
if id mysql >/dev/null 2>&1; then
  chown mysql:mysql /tmp/kiln-server.crt /tmp/kiln-server.key /tmp/kiln-ca.crt
fi
chmod 600 /tmp/kiln-server.key
chmod 644 /tmp/kiln-server.crt /tmp/kiln-ca.crt
exec docker-entrypoint.sh mariadbd \
  --character-set-server=utf8mb4 \
  --collation-server=utf8mb4_uca1400_ai_ci \
  --default-time-zone=+00:00 \
  --ssl-ca=/tmp/kiln-ca.crt \
  --ssl-cert=/tmp/kiln-server.crt \
  --ssl-key=/tmp/kiln-server.key
