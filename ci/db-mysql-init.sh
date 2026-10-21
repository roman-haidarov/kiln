#!/bin/sh
set -eu
mysql --protocol=socket -uroot -p"$MYSQL_ROOT_PASSWORD" -e "ALTER USER '${MYSQL_USER}'@'%' IDENTIFIED WITH caching_sha2_password BY '${MYSQL_PASSWORD}'"
