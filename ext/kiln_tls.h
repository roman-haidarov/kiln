#ifndef KILN_TLS_H
#define KILN_TLS_H

#include <stddef.h>

#define KILN_TLS_MAX_CONTEXTS 16

enum {
    KILN_TLS_WANT = 0,
    KILN_TLS_DONE = 1,
    KILN_TLS_FAIL = -1,
    KILN_TLS_CLOSED = -2,
    KILN_TLS_WANT_WRITE = 2,
    KILN_TLS_WANT_READ = 3
};

typedef struct kiln_tls_conn kiln_tls_conn;

long kiln_tls_available(void);
const char *kiln_tls_error_text(void);
long kiln_tls_context_new(const char *cert, const char *key, const char *ca, long verify,
    const char *ciphers, const char *suites, long min_version, const char *alpn);
long kiln_tls_context_free(long index);
kiln_tls_conn *kiln_tls_conn_new(long context);
void kiln_tls_conn_free(kiln_tls_conn *conn);
int kiln_tls_feed(kiln_tls_conn *conn, const char *data, size_t len);
int kiln_tls_handshake(kiln_tls_conn *conn);
long kiln_tls_read(kiln_tls_conn *conn, char *out, size_t cap);
int kiln_tls_write(kiln_tls_conn *conn, const char *data, size_t len, size_t *consumed);
size_t kiln_tls_pending(kiln_tls_conn *conn);
size_t kiln_tls_take(kiln_tls_conn *conn, char *out, size_t cap);
void kiln_tls_close_notify(kiln_tls_conn *conn);
const char *kiln_tls_selected(kiln_tls_conn *conn, size_t *len);
const char *kiln_tls_protocol(kiln_tls_conn *conn);

#endif
