#include <libpq-fe.h>
#include <mysql.h>
#include <mariadb_com.h>
#include <errno.h>
#include <limits.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *need(const char *key) {
    const char *value = getenv(key);
    if (!value || !value[0]) {
        fprintf(stderr, "missing %s\n", key);
        exit(2);
    }
    return value;
}

static int parse_uint(const char *text, unsigned int *out) {
    unsigned long value;
    char *end;
    const unsigned char *p = (const unsigned char *)text;
    if (!text || !text[0] || !out) {
        return 0;
    }
    for (; *p; p++) {
        if (*p < '0' || *p > '9') {
            return 0;
        }
    }
    errno = 0;
    value = strtoul(text, &end, 10);
    if (errno || *end || value > UINT_MAX) {
        return 0;
    }
    *out = (unsigned int)value;
    return 1;
}

static int probe_pg(void) {
    const char *host = need("KILN_DB_PROBE_HOST");
    const char *name = need("KILN_DB_PROBE_TLS_NAME");
    const char *port = need("KILN_DB_PROBE_PORT");
    const char *user = need("KILN_DB_PROBE_USER");
    const char *pass = need("KILN_DB_PROBE_PASSWORD");
    const char *db = need("KILN_DB_PROBE_DB");
    const char *ca = need("KILN_DB_PROBE_CA");
    const char *timeout = need("KILN_DB_PROBE_TIMEOUT");
    char info[2048];
    PGconn *conn;
    PGresult *res;
    int n;
    n = snprintf(info, sizeof info,
        "host=%s hostaddr=%s port=%s user=%s password=%s dbname=%s "
        "sslmode=verify-full sslrootcert=%s connect_timeout=%s",
        name, host, port, user, pass, db, ca, timeout);
    if (n < 0 || (size_t)n >= sizeof info) {
        fprintf(stderr, "pg conninfo overflow\n");
        return 1;
    }
    conn = PQconnectdb(info);
    if (PQstatus(conn) != CONNECTION_OK) {
        fprintf(stderr, "pg connect failed: %s\n", PQerrorMessage(conn));
        PQfinish(conn);
        return 1;
    }
    res = PQexec(conn, "SELECT version()");
    if (PQresultStatus(res) != PGRES_TUPLES_OK || PQntuples(res) != 1) {
        fprintf(stderr, "pg version query failed\n");
        PQclear(res);
        PQfinish(conn);
        return 1;
    }
    printf("pg_version=%s\n", PQgetvalue(res, 0, 0));
    PQclear(res);
    res = PQexec(conn, "SELECT 1");
    if (PQresultStatus(res) != PGRES_TUPLES_OK || PQntuples(res) != 1) {
        fprintf(stderr, "pg select 1 failed\n");
        PQclear(res);
        PQfinish(conn);
        return 1;
    }
    printf("pg_select1=%s\n", PQgetvalue(res, 0, 0));
    PQclear(res);
    PQfinish(conn);
    return 0;
}

static int loopback_name(const char *name) {
    return strcmp(name, "127.0.0.1") == 0 || strcmp(name, "::1") == 0;
}

static int probe_my(void) {
    const char *bind_host = need("KILN_DB_PROBE_HOST");
    const char *name = need("KILN_DB_PROBE_TLS_NAME");
    const char *port_text = need("KILN_DB_PROBE_PORT");
    const char *user = need("KILN_DB_PROBE_USER");
    const char *pass = need("KILN_DB_PROBE_PASSWORD");
    const char *db = need("KILN_DB_PROBE_DB");
    const char *ca = need("KILN_DB_PROBE_CA");
    const char *timeout_text = need("KILN_DB_PROBE_TIMEOUT");
    unsigned int port;
    unsigned int protocol = MYSQL_PROTOCOL_TCP;
    unsigned int timeout;
    unsigned int tls_status = 1;
    unsigned int got_port = 0;
    int pvio_type = -1;
    char *got_host = NULL;
    MYSQL *mysql;
    MYSQL_RES *res;
    MYSQL_ROW row;
    my_bool verify = 1;
    const char *cipher;
    if (!parse_uint(port_text, &port) || port == 0 || port > 65535 ||
        !parse_uint(timeout_text, &timeout) || timeout == 0) {
        fprintf(stderr, "invalid my probe port or timeout\n");
        return 1;
    }
    if (!loopback_name(bind_host)) {
        fprintf(stderr, "my probe host is not loopback\n");
        return 1;
    }
    if (loopback_name(name)) {
        fprintf(stderr, "my tls name skips hostname verification\n");
        return 1;
    }
    mysql = mysql_init(NULL);
    if (!mysql) {
        fprintf(stderr, "mysql_init failed\n");
        return 1;
    }
    if (mysql_options(mysql, MYSQL_OPT_PROTOCOL, &protocol) != 0) {
        fprintf(stderr, "my protocol option failed\n");
        mysql_close(mysql);
        return 1;
    }
    if (mysql_options(mysql, MYSQL_OPT_CONNECT_TIMEOUT, &timeout) != 0) {
        fprintf(stderr, "my connect timeout option failed\n");
        mysql_close(mysql);
        return 1;
    }
    if (mysql_ssl_set(mysql, NULL, NULL, ca, NULL, NULL) != 0) {
        fprintf(stderr, "mysql_ssl_set failed\n");
        mysql_close(mysql);
        return 1;
    }
    if (mysql_options(mysql, MYSQL_OPT_SSL_VERIFY_SERVER_CERT, &verify) != 0) {
        fprintf(stderr, "mysql ssl verify option failed\n");
        mysql_close(mysql);
        return 1;
    }
    if (!mysql_real_connect(mysql, name, user, pass, db, port, NULL, CLIENT_SSL)) {
        fprintf(stderr, "my connect failed: %s\n", mysql_error(mysql));
        mysql_close(mysql);
        return 1;
    }
    if (mariadb_get_infov(mysql, MARIADB_CONNECTION_TYPE, &pvio_type) != 0 || pvio_type != 1) {
        fprintf(stderr, "my transport is not tcp\n");
        mysql_close(mysql);
        return 1;
    }
    if (mariadb_get_infov(mysql, MARIADB_CONNECTION_HOST, (void *)&got_host) != 0 || !got_host ||
        strcmp(got_host, name) != 0) {
        fprintf(stderr, "my verified name mismatch\n");
        mysql_close(mysql);
        return 1;
    }
    if (mariadb_get_infov(mysql, MARIADB_CONNECTION_PORT, &got_port) != 0 || got_port != port) {
        fprintf(stderr, "my port mismatch\n");
        mysql_close(mysql);
        return 1;
    }
    cipher = mysql_get_ssl_cipher(mysql);
    if (!cipher || !cipher[0]) {
        fprintf(stderr, "my cipher empty\n");
        mysql_close(mysql);
        return 1;
    }
    printf("my_cipher=%s\n", cipher);
    if (mariadb_get_infov(mysql, MARIADB_TLS_VERIFY_STATUS, &tls_status) != 0) {
        fprintf(stderr, "my tls status unavailable\n");
        mysql_close(mysql);
        return 1;
    }
    printf("my_tls_status=%u\n", tls_status);
    if (tls_status != MARIADB_TLS_VERIFY_OK) {
        fprintf(stderr, "my tls verify failed status %u\n", tls_status);
        mysql_close(mysql);
        return 1;
    }
    printf("my_tls_name=%s\n", name);
    if (mysql_query(mysql, "SELECT VERSION()") != 0) {
        fprintf(stderr, "my version query failed: %s\n", mysql_error(mysql));
        mysql_close(mysql);
        return 1;
    }
    res = mysql_store_result(mysql);
    row = res ? mysql_fetch_row(res) : NULL;
    if (!row || !row[0]) {
        fprintf(stderr, "my version empty\n");
        if (res) {
            mysql_free_result(res);
        }
        mysql_close(mysql);
        return 1;
    }
    printf("my_version=%s\n", row[0]);
    mysql_free_result(res);
    if (mysql_query(mysql, "SELECT 1") != 0) {
        fprintf(stderr, "my select 1 failed\n");
        mysql_close(mysql);
        return 1;
    }
    res = mysql_store_result(mysql);
    row = res ? mysql_fetch_row(res) : NULL;
    if (!row || !row[0]) {
        fprintf(stderr, "my select 1 empty\n");
        if (res) {
            mysql_free_result(res);
        }
        mysql_close(mysql);
        return 1;
    }
    printf("my_select1=%s\n", row[0]);
    mysql_free_result(res);
    mysql_close(mysql);
    return 0;
}

int main(void) {
    const char *mode = need("KILN_DB_PROBE_MODE");
    if (strcmp(mode, "pg") == 0) {
        return probe_pg();
    }
    if (strcmp(mode, "my") == 0) {
        return probe_my();
    }
    fprintf(stderr, "unknown probe mode\n");
    return 2;
}
