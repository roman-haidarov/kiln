#!/bin/sh
set -eu
cp /kiln-config/server.crt /tmp/kiln-server.crt
cp /kiln-config/server.key /tmp/kiln-server.key
cp /kiln-config/ca.crt /tmp/kiln-ca.crt
chown postgres:postgres /tmp/kiln-server.crt /tmp/kiln-server.key /tmp/kiln-ca.crt
chmod 600 /tmp/kiln-server.key
chmod 644 /tmp/kiln-server.crt /tmp/kiln-ca.crt
exec docker-entrypoint.sh postgres \
  -c ssl=on \
  -c ssl_cert_file=/tmp/kiln-server.crt \
  -c ssl_key_file=/tmp/kiln-server.key \
  -c ssl_ca_file=/tmp/kiln-ca.crt \
  -c timezone=UTC
