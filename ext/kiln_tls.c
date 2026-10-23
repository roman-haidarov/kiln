#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "kiln_tls.h"

#ifdef SP_THREADS
extern __thread int sp_ffi_bin_len;
#else
extern int sp_ffi_bin_len;
#endif

#define KTLS_FILETYPE_PEM        1
#define KTLS_ERROR_WANT_READ     2
#define KTLS_ERROR_WANT_WRITE    3
#define KTLS_ERROR_ZERO_RETURN   6
#define KTLS_CTRL_MODE           33
#define KTLS_CTRL_SESS_CACHE     44
#define KTLS_CTRL_MIN_PROTO      123
#define KTLS_MODE_RELEASE        0x10L
#define KTLS_SESS_CACHE_SERVER   0x0002L
#define KTLS_OP_NO_COMPRESSION   0x00020000UL
#define KTLS_OP_SERVER_PREF      0x00400000UL
#define KTLS_OP_NO_RENEGOTIATION 0x40000000UL
#define KTLS_VERIFY_PEER         1
#define KTLS_VERIFY_REQUIRE      2
#define KTLS_ALPN_OK             0
#define KTLS_ALPN_FATAL          2
#define KTLS_ALPN_NOACK          3
#define KTLS_NEGOTIATED          1
#define KTLS_ALPN_MAX            255
#define KTLS_ALPN_ID_MAX         255
#define KTLS_RECORD_MAX          16384

typedef struct ssl_ctx_st SSL_CTX;
typedef struct ssl_st SSL;
typedef struct ssl_method_st SSL_METHOD;
typedef struct bio_st BIO;
typedef struct bio_method_st BIO_METHOD;
typedef struct stack_st STACK;
typedef int (*ktls_alpn_cb)(
    SSL *, const unsigned char **, unsigned char *, const unsigned char *, unsigned int, void *);

typedef struct {
    const SSL_METHOD *(*server_method)(void);
    SSL_CTX *(*ctx_new)(const SSL_METHOD *);
    void (*ctx_free)(SSL_CTX *);
    long (*ctx_ctrl)(SSL_CTX *, int, long, void *);
    uint64_t (*ctx_set_options)(SSL_CTX *, uint64_t);
    int (*use_chain)(SSL_CTX *, const char *);
    int (*use_key)(SSL_CTX *, const char *, int);
    int (*check_key)(const SSL_CTX *);
    int (*cipher_list)(SSL_CTX *, const char *);
    int (*ciphersuites)(SSL_CTX *, const char *);
    int (*verify_locations)(SSL_CTX *, const char *, const char *);
    void (*set_verify)(SSL_CTX *, int, void *);
    STACK *(*load_client_ca)(const char *);
    void (*set_client_ca)(SSL_CTX *, STACK *);
    void (*set_alpn_cb)(SSL_CTX *, ktls_alpn_cb, void *);
    int (*sid_context)(SSL_CTX *, const unsigned char *, unsigned int);
    int (*select_next)(unsigned char **, unsigned char *, const unsigned char *, unsigned int,
        const unsigned char *, unsigned int);
    SSL *(*ssl_new)(SSL_CTX *);
    void (*ssl_free)(SSL *);
    void (*set_bio)(SSL *, BIO *, BIO *);
    void (*accept_state)(SSL *);
    int (*handshake)(SSL *);
    int (*read)(SSL *, void *, int);
    int (*write)(SSL *, const void *, int);
    int (*get_error)(const SSL *, int);
    int (*shutdown)(SSL *);
    void (*alpn_selected)(const SSL *, const unsigned char **, unsigned int *);
    const char *(*version)(const SSL *);
    BIO *(*bio_new)(const BIO_METHOD *);
    const BIO_METHOD *(*bio_mem)(void);
    int (*bio_read)(BIO *, void *, int);
    int (*bio_write)(BIO *, const void *, int);
    size_t (*bio_pending)(BIO *);
    int (*bio_free)(BIO *);
    unsigned long (*err_get)(void);
    void (*err_string)(unsigned long, char *, size_t);
    void (*err_clear)(void);
} ktls_api;

typedef struct {
    SSL_CTX *ctx;
    unsigned char alpn[KTLS_ALPN_MAX + 1];
    unsigned int alpn_len;
    int in_use;
} ktls_context;

struct kiln_tls_conn {
    SSL *ssl;
    BIO *rbio;
    BIO *wbio;
};

static ktls_api ktls;
static int ktls_loaded;
static pthread_once_t ktls_once = PTHREAD_ONCE_INIT;
static pthread_mutex_t ktls_lock = PTHREAD_MUTEX_INITIALIZER;
static ktls_context ktls_contexts[KILN_TLS_MAX_CONTEXTS];
static char ktls_load_error[512];
static __thread char ktls_error[512];

static const char *const ktls_ssl_names[] = {"libssl.so.3", "libssl.so.1.1", "libssl.so",
    "libssl.3.dylib", "/opt/homebrew/opt/openssl@3/lib/libssl.3.dylib",
    "/usr/local/opt/openssl@3/lib/libssl.3.dylib", "/opt/homebrew/lib/libssl.3.dylib",
    "/usr/local/lib/libssl.3.dylib", NULL};
static const char *const ktls_crypto_names[] = {"libcrypto.so.3", "libcrypto.so.1.1",
    "libcrypto.so", "libcrypto.3.dylib", "/opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib",
    "/usr/local/opt/openssl@3/lib/libcrypto.3.dylib", "/opt/homebrew/lib/libcrypto.3.dylib",
    "/usr/local/lib/libcrypto.3.dylib", NULL};

static void *ktls_open(const char *env, const char *const *names) {
    const char *path = getenv(env);
    if (path && *path)
        return dlopen(path, RTLD_NOW | RTLD_LOCAL);
    for (int i = 0; names[i]; i++) {
        void *handle = dlopen(names[i], RTLD_NOW | RTLD_LOCAL);
        if (handle)
            return handle;
    }
    return NULL;
}

static void *ktls_sym(void *ssl, void *crypto, const char *name, int *missing) {
    void *found = dlsym(ssl, name);
    if (!found && crypto)
        found = dlsym(crypto, name);
    if (!found)
        *missing = 1;
    return found;
}

static void ktls_bind(void *slot, void *ssl, void *crypto, const char *name, int *missing) {
    void *found = ktls_sym(ssl, crypto, name, missing);
    memcpy(slot, (const void *)&found, sizeof found);
}

#define KTLS_BIND(field, name) ktls_bind((void *)&ktls.field, ssl, crypto, name, &missing)

static void ktls_load(void) {
    void *ssl = ktls_open("KILN_LIBSSL", ktls_ssl_names);
    if (!ssl) {
        snprintf(ktls_load_error, sizeof ktls_load_error, "libssl not found (set KILN_LIBSSL)");
        return;
    }
    void *crypto = ktls_open("KILN_LIBCRYPTO", ktls_crypto_names);
    int missing = 0;
    KTLS_BIND(server_method, "TLS_server_method");
    KTLS_BIND(ctx_new, "SSL_CTX_new");
    KTLS_BIND(ctx_free, "SSL_CTX_free");
    KTLS_BIND(ctx_ctrl, "SSL_CTX_ctrl");
    KTLS_BIND(ctx_set_options, "SSL_CTX_set_options");
    KTLS_BIND(use_chain, "SSL_CTX_use_certificate_chain_file");
    KTLS_BIND(use_key, "SSL_CTX_use_PrivateKey_file");
    KTLS_BIND(check_key, "SSL_CTX_check_private_key");
    KTLS_BIND(cipher_list, "SSL_CTX_set_cipher_list");
    KTLS_BIND(ciphersuites, "SSL_CTX_set_ciphersuites");
    KTLS_BIND(verify_locations, "SSL_CTX_load_verify_locations");
    KTLS_BIND(set_verify, "SSL_CTX_set_verify");
    KTLS_BIND(load_client_ca, "SSL_load_client_CA_file");
    KTLS_BIND(set_client_ca, "SSL_CTX_set_client_CA_list");
    KTLS_BIND(set_alpn_cb, "SSL_CTX_set_alpn_select_cb");
    KTLS_BIND(sid_context, "SSL_CTX_set_session_id_context");
    KTLS_BIND(select_next, "SSL_select_next_proto");
    KTLS_BIND(ssl_new, "SSL_new");
    KTLS_BIND(ssl_free, "SSL_free");
    KTLS_BIND(set_bio, "SSL_set_bio");
    KTLS_BIND(accept_state, "SSL_set_accept_state");
    KTLS_BIND(handshake, "SSL_do_handshake");
    KTLS_BIND(read, "SSL_read");
    KTLS_BIND(write, "SSL_write");
    KTLS_BIND(get_error, "SSL_get_error");
    KTLS_BIND(shutdown, "SSL_shutdown");
    KTLS_BIND(alpn_selected, "SSL_get0_alpn_selected");
    KTLS_BIND(version, "SSL_get_version");
    KTLS_BIND(bio_new, "BIO_new");
    KTLS_BIND(bio_mem, "BIO_s_mem");
    KTLS_BIND(bio_read, "BIO_read");
    KTLS_BIND(bio_write, "BIO_write");
    KTLS_BIND(bio_pending, "BIO_ctrl_pending");
    KTLS_BIND(bio_free, "BIO_free");
    KTLS_BIND(err_get, "ERR_get_error");
    KTLS_BIND(err_string, "ERR_error_string_n");
    KTLS_BIND(err_clear, "ERR_clear_error");
    if (missing) {
        snprintf(ktls_load_error, sizeof ktls_load_error, "libssl lacks OpenSSL 1.1.1 symbols");
        return;
    }
    ktls_loaded = 1;
}

static int ktls_ready(void) {
    pthread_once(&ktls_once, ktls_load);
    if (!ktls_loaded) {
        snprintf(ktls_error, sizeof ktls_error, "%s", ktls_load_error);
    }
    return ktls_loaded;
}

static void ktls_context_release_slot(ktls_context *context) {
    pthread_mutex_lock(&ktls_lock);
    context->in_use = 0;
    pthread_mutex_unlock(&ktls_lock);
}

static long ktls_fail(const char *what) {
    unsigned long code = ktls.err_get ? ktls.err_get() : 0;
    char detail[256] = "";
    if (code)
        ktls.err_string(code, detail, sizeof detail);
    snprintf(ktls_error, sizeof ktls_error, "%s%s%s", what, *detail ? ": " : "", detail);
    if (ktls.err_clear)
        ktls.err_clear();
    return -1;
}

static int ktls_alpn_select(SSL *ssl, const unsigned char **out, unsigned char *out_len,
    const unsigned char *in, unsigned int in_len, void *arg) {
    (void)ssl;
    const ktls_context *context = arg;
    unsigned char *chosen = NULL;
    unsigned char chosen_len = 0;
    if (context->alpn_len == 0 || in_len == 0)
        return KTLS_ALPN_NOACK;
    int rc = ktls.select_next(&chosen, &chosen_len, context->alpn, context->alpn_len, in, in_len);
    if (rc != KTLS_NEGOTIATED)
        return KTLS_ALPN_FATAL;
    *out = chosen;
    *out_len = chosen_len;
    return KTLS_ALPN_OK;
}

static int ktls_alpn_wire(ktls_context *context, const char *list) {
    unsigned int len = 0;
    const char *at = list;
    while (at && *at) {
        const char *comma = strchr(at, ',');
        size_t n = comma ? (size_t)(comma - at) : strlen(at);
        if (n == 0 || n > KTLS_ALPN_ID_MAX || len + 1 + n > KTLS_ALPN_MAX)
            return -1;
        context->alpn[len++] = (unsigned char)n;
        memcpy(context->alpn + len, at, n);
        len += (unsigned int)n;
        at = comma ? comma + 1 : NULL;
    }
    context->alpn_len = len;
    return 0;
}

static long ktls_configure(ktls_context *context, const char *cert, const char *key, const char *ca,
    long verify, const char *ciphers, const char *suites, long min_version) {
    SSL_CTX *ctx = context->ctx;
    ktls.ctx_set_options(
        ctx, KTLS_OP_NO_COMPRESSION | KTLS_OP_SERVER_PREF | KTLS_OP_NO_RENEGOTIATION);
    ktls.ctx_ctrl(ctx, KTLS_CTRL_MODE, KTLS_MODE_RELEASE, NULL);
    ktls.ctx_ctrl(ctx, KTLS_CTRL_SESS_CACHE, KTLS_SESS_CACHE_SERVER, NULL);
    ktls.sid_context(ctx, (const unsigned char *)"kiln", 4);
    if (ktls.ctx_ctrl(ctx, KTLS_CTRL_MIN_PROTO, min_version, NULL) != 1)
        return ktls_fail("unsupported min_version");
    if (ktls.use_chain(ctx, cert) != 1)
        return ktls_fail("cannot load certificate chain");
    if (ktls.use_key(ctx, key, KTLS_FILETYPE_PEM) != 1)
        return ktls_fail("cannot load private key");
    if (ktls.check_key(ctx) != 1)
        return ktls_fail("private key does not match certificate");
    if (*ciphers && ktls.cipher_list(ctx, ciphers) != 1)
        return ktls_fail("invalid ciphers");
    if (*suites && ktls.ciphersuites(ctx, suites) != 1)
        return ktls_fail("invalid ciphersuites");
    if (*ca) {
        if (ktls.verify_locations(ctx, ca, NULL) != 1)
            return ktls_fail("cannot load client CA");
        STACK *names = ktls.load_client_ca(ca);
        if (names)
            ktls.set_client_ca(ctx, names);
    }
    if (verify > 0)
        ktls.set_verify(
            ctx, verify > 1 ? KTLS_VERIFY_PEER | KTLS_VERIFY_REQUIRE : KTLS_VERIFY_PEER, NULL);
    ktls.set_alpn_cb(ctx, ktls_alpn_select, context);
    return 0;
}

long kiln_tls_available(void) {
    return ktls_ready();
}

const char *kiln_tls_error_text(void) {
    if (!ktls_error[0]) {
        ktls_ready();
    }
    sp_ffi_bin_len = (int)strlen(ktls_error);
    return ktls_error;
}

long kiln_tls_context_new(const char *cert, const char *key, const char *ca, long verify,
    const char *ciphers, const char *suites, long min_version, const char *alpn) {
    if (!ktls_ready())
        return -1;
    pthread_mutex_lock(&ktls_lock);
    long index = -1;
    for (long i = 0; i < KILN_TLS_MAX_CONTEXTS; i++) {
        if (!ktls_contexts[i].in_use) {
            index = i;
            break;
        }
    }
    if (index < 0) {
        pthread_mutex_unlock(&ktls_lock);
        snprintf(ktls_error, sizeof ktls_error, "too many TLS contexts");
        return -1;
    }
    ktls_context *context = &ktls_contexts[index];
    memset(context, 0, sizeof *context);
    context->in_use = 1;
    pthread_mutex_unlock(&ktls_lock);
    if (ktls_alpn_wire(context, alpn) < 0) {
        ktls_context_release_slot(context);
        snprintf(ktls_error, sizeof ktls_error, "invalid ALPN protocol list");
        return -1;
    }
    context->ctx = ktls.ctx_new(ktls.server_method());
    if (!context->ctx) {
        ktls_context_release_slot(context);
        return ktls_fail("cannot create TLS context");
    }
    if (ktls_configure(context, cert, key, ca, verify, ciphers, suites, min_version) < 0) {
        ktls.ctx_free(context->ctx);
        context->ctx = NULL;
        ktls_context_release_slot(context);
        return -1;
    }
    return index;
}

long kiln_tls_context_free(long index) {
    if (index < 0 || index >= KILN_TLS_MAX_CONTEXTS)
        return -1;
    pthread_mutex_lock(&ktls_lock);
    if (!ktls_contexts[index].in_use) {
        pthread_mutex_unlock(&ktls_lock);
        return -1;
    }
    ktls.ctx_free(ktls_contexts[index].ctx);
    ktls_contexts[index].ctx = NULL;
    ktls_contexts[index].in_use = 0;
    pthread_mutex_unlock(&ktls_lock);
    return 0;
}

kiln_tls_conn *kiln_tls_conn_new(long context) {
    if (context < 0 || context >= KILN_TLS_MAX_CONTEXTS)
        return NULL;
    kiln_tls_conn *conn = calloc(1, sizeof *conn);
    if (!conn)
        return NULL;
    pthread_mutex_lock(&ktls_lock);
    if (!ktls_contexts[context].in_use || !ktls_contexts[context].ctx) {
        pthread_mutex_unlock(&ktls_lock);
        free(conn);
        return NULL;
    }
    conn->ssl = ktls.ssl_new(ktls_contexts[context].ctx);
    pthread_mutex_unlock(&ktls_lock);
    conn->rbio = ktls.bio_new(ktls.bio_mem());
    conn->wbio = ktls.bio_new(ktls.bio_mem());
    if (!conn->ssl || !conn->rbio || !conn->wbio) {
        if (conn->rbio)
            ktls.bio_free(conn->rbio);
        if (conn->wbio)
            ktls.bio_free(conn->wbio);
        if (conn->ssl)
            ktls.ssl_free(conn->ssl);
        free(conn);
        return NULL;
    }
    ktls.set_bio(conn->ssl, conn->rbio, conn->wbio);
    ktls.accept_state(conn->ssl);
    return conn;
}

void kiln_tls_conn_free(kiln_tls_conn *conn) {
    if (!conn)
        return;
    ktls.ssl_free(conn->ssl);
    free(conn);
}

int kiln_tls_feed(kiln_tls_conn *conn, const char *data, size_t len) {
    while (len > 0) {
        int chunk = len > (size_t)INT32_MAX ? INT32_MAX : (int)len;
        int wrote = ktls.bio_write(conn->rbio, data, chunk);
        if (wrote <= 0)
            return KILN_TLS_FAIL;
        data += wrote;
        len -= (size_t)wrote;
    }
    return KILN_TLS_DONE;
}

static int ktls_status(kiln_tls_conn *conn, int rc) {
    int err = ktls.get_error(conn->ssl, rc);
    if (err == KTLS_ERROR_WANT_READ || err == KTLS_ERROR_WANT_WRITE)
        return KILN_TLS_WANT;
    ktls.err_clear();
    return err == KTLS_ERROR_ZERO_RETURN ? KILN_TLS_CLOSED : KILN_TLS_FAIL;
}

int kiln_tls_handshake(kiln_tls_conn *conn) {
    int rc = ktls.handshake(conn->ssl);
    return rc == 1 ? KILN_TLS_DONE : ktls_status(conn, rc);
}

long kiln_tls_read(kiln_tls_conn *conn, char *out, size_t cap) {
    int want = cap > (size_t)INT32_MAX ? INT32_MAX : (int)cap;
    int rc = ktls.read(conn->ssl, out, want);
    return rc > 0 ? rc : ktls_status(conn, rc);
}

int kiln_tls_write(kiln_tls_conn *conn, const char *data, size_t len, size_t *consumed) {
    *consumed = 0;
    while (len > 0) {
        int chunk = len > KTLS_RECORD_MAX ? KTLS_RECORD_MAX : (int)len;
        int rc = ktls.write(conn->ssl, data, chunk);
        if (rc <= 0) {
            int err = ktls.get_error(conn->ssl, rc);
            if (err == KTLS_ERROR_WANT_READ || err == KTLS_ERROR_WANT_WRITE)
                return err == KTLS_ERROR_WANT_READ ? KILN_TLS_WANT_READ : KILN_TLS_WANT_WRITE;
            ktls.err_clear();
            return err == KTLS_ERROR_ZERO_RETURN ? KILN_TLS_CLOSED : KILN_TLS_FAIL;
        }
        data += rc;
        len -= (size_t)rc;
        *consumed += (size_t)rc;
    }
    return KILN_TLS_DONE;
}

size_t kiln_tls_pending(kiln_tls_conn *conn) {
    return ktls.bio_pending(conn->wbio);
}

size_t kiln_tls_take(kiln_tls_conn *conn, char *out, size_t cap) {
    int want = cap > (size_t)INT32_MAX ? INT32_MAX : (int)cap;
    int rc = ktls.bio_read(conn->wbio, out, want);
    return rc > 0 ? (size_t)rc : 0;
}

void kiln_tls_close_notify(kiln_tls_conn *conn) {
    ktls.shutdown(conn->ssl);
    ktls.err_clear();
}

const char *kiln_tls_selected(kiln_tls_conn *conn, size_t *len) {
    const unsigned char *data = NULL;
    unsigned int n = 0;
    ktls.alpn_selected(conn->ssl, &data, &n);
    *len = n;
    return (const char *)data;
}

const char *kiln_tls_protocol(kiln_tls_conn *conn) {
    return ktls.version(conn->ssl);
}
