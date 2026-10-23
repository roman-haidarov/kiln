#include "kiln_db.h"

#include <arpa/inet.h>
#include <dlfcn.h>
#include <limits.h>
#include <libpq-fe.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#if !defined(LIBPQ_HAS_ASYNC_CANCEL) || !defined(LIBPQ_HAS_CHUNK_MODE) || \
    !defined(LIBPQ_HAS_PIPELINING)
#error "Kiln::DB needs libpq >= 17 headers: set KILN_DB_LIBPQ_PREFIX to a libpq 17+ install"
#endif

#define PG_PUMP_MAX 32
#define PG_SEEN 64
#define PG_CLOSE_MAX 8
#define PG_NAME_MAX 24
#define PG_GO 100
#define PG_DONE 101
#define PG_C_NONE 0
#define PG_C_CLOSE 1
#define PG_C_PREPARE 2
#define PG_C_EXEC 3
#define PG_C_RETRY 4
#define PG_C_PLAIN 5
#define PG_N_PLAIN 0
#define PG_N_PREPARE 1

typedef struct {
    int (*PQlibVersion)(void);
    PGconn *(*PQconnectStartParams)(
        const char *const *keywords, const char *const *values, int expand_dbname);
    PostgresPollingStatusType (*PQconnectPoll)(PGconn *conn);
    ConnStatusType (*PQstatus)(const PGconn *conn);
    int (*PQsetnonblocking)(PGconn *conn, int arg);
    int (*PQsocket)(const PGconn *conn);
    int (*PQsendPrepare)(
        PGconn *conn, const char *stmtName, const char *query, int nParams, const Oid *paramTypes);
    int (*PQsendQueryPrepared)(PGconn *conn, const char *stmtName, int nParams,
        const char *const *paramValues, const int *paramLengths, const int *paramFormats,
        int resultFormat);
    int (*PQsendQueryParams)(PGconn *conn, const char *command, int nParams, const Oid *paramTypes,
        const char *const *paramValues, const int *paramLengths, const int *paramFormats,
        int resultFormat);
    int (*PQsendClosePrepared)(PGconn *conn, const char *stmt);
    PGTransactionStatusType (*PQtransactionStatus)(const PGconn *conn);
    int (*PQflush)(PGconn *conn);
    int (*PQconsumeInput)(PGconn *conn);
    int (*PQisBusy)(PGconn *conn);
    PGresult *(*PQgetResult)(PGconn *conn);
    ExecStatusType (*PQresultStatus)(const PGresult *res);
    char *(*PQresultErrorField)(const PGresult *res, int fieldcode);
    int (*PQntuples)(const PGresult *res);
    int (*PQnfields)(const PGresult *res);
    char *(*PQgetvalue)(const PGresult *res, int tup_num, int field_num);
    int (*PQgetlength)(const PGresult *res, int tup_num, int field_num);
    int (*PQgetisnull)(const PGresult *res, int tup_num, int field_num);
    void (*PQclear)(PGresult *res);
    int (*PQsetChunkedRowsMode)(PGconn *conn, int chunkSize);
    char *(*PQerrorMessage)(const PGconn *conn);
    void (*PQfinish)(PGconn *conn);
    int (*PQenterPipelineMode)(PGconn *conn);
    int (*PQexitPipelineMode)(PGconn *conn);
    int (*PQsendPipelineSync)(PGconn *conn);
    int (*PQsendFlushRequest)(PGconn *conn);
    PGpipelineStatus (*PQpipelineStatus)(const PGconn *conn);
    int (*PQsslInUse)(PGconn *conn);
    PGcancelConn *(*PQcancelCreate)(PGconn *conn);
    int (*PQcancelStart)(PGcancelConn *cancelConn);
    PostgresPollingStatusType (*PQcancelPoll)(PGcancelConn *cancelConn);
    int (*PQcancelSocket)(const PGcancelConn *cancelConn);
    void (*PQcancelFinish)(PGcancelConn *cancelConn);
    PQnoticeProcessor (*PQsetNoticeProcessor)(PGconn *conn, PQnoticeProcessor proc, void *arg);
    Oid (*PQftype)(const PGresult *res, int field_num);
    char *(*PQresultErrorMessage)(const PGresult *res);
    unsigned char *(*PQunescapeBytea)(const unsigned char *strtext, size_t *retbuflen);
    void (*PQfreemem)(void *ptr);
} pg_api;

typedef struct {
    uint64_t hash;
    char *sql;
    size_t len;
    uint64_t stamp;
    int stale;
    char name[PG_NAME_MAX];
} pg_stmt_ent;

typedef struct {
    PGconn *pg;
    PGresult *held;
    PGcancelConn *cancel;
    int phase;
    int fatal;
    int settle;
    int pump;
    int nparams;
    int bind_phase;
    int pcap;
    int *formats;
    int *lengths;
    char **values;
    char *host_list;
    long notices;
    char port_text[8];
    char fatal_state[6];
    char fatal_message[512];
    int fatal_code;
    int pipeline;
    int inflight;
    int sync_mark;
    int hold_tail;
    const char *keys[12];
    const char *vals[12];
    pg_stmt_ent *cache;
    int cache_cap;
    int cache_used;
    uint64_t cache_clock;
    uint64_t cache_serial;
    uint64_t seen[PG_SEEN];
    int seen_at;
    int cstage;
    int cnext;
    int cretry;
    int creset;
    uint64_t pend_hash;
    char pend_name[PG_NAME_MAX];
    char run_name[PG_NAME_MAX];
    char close_q[PG_CLOSE_MAX][PG_NAME_MAX];
    int close_n;
} pg_sess;

typedef struct {
    int count;
    const char *const *values;
    const int *lengths;
    const int *formats;
} conn_params;

static pg_api pg;
static void *pg_lib;
static pthread_mutex_t pg_mu = PTHREAD_MUTEX_INITIALIZER;
static int pg_loaded;
static int pg_load_rc = KILN_DB_CONN;
static long pg_version;

static const char *const pg_names[] = {"libpq.5.dylib", "libpq.dylib",
    "/opt/homebrew/opt/libpq/lib/libpq.5.dylib", "/opt/homebrew/opt/libpq/lib/libpq.dylib",
    "libpq.so.5", "libpq.so", NULL};

static int pg_need(void **slot, const char *name) {
    void *sym = dlsym(pg_lib, name);
    if (!sym) {
        kiln_db_set_load_error(name);
        return -1;
    }
    memcpy(slot, &sym, sizeof sym);
    return 0;
}

static int pg_bind(void) {
    if (pg_need((void **)&pg.PQlibVersion, "PQlibVersion") ||
        pg_need((void **)&pg.PQconnectStartParams, "PQconnectStartParams") ||
        pg_need((void **)&pg.PQconnectPoll, "PQconnectPoll") ||
        pg_need((void **)&pg.PQstatus, "PQstatus") ||
        pg_need((void **)&pg.PQsetnonblocking, "PQsetnonblocking") ||
        pg_need((void **)&pg.PQsocket, "PQsocket") ||
        pg_need((void **)&pg.PQsendPrepare, "PQsendPrepare") ||
        pg_need((void **)&pg.PQsendQueryPrepared, "PQsendQueryPrepared") ||
        pg_need((void **)&pg.PQsendQueryParams, "PQsendQueryParams") ||
        pg_need((void **)&pg.PQsendClosePrepared, "PQsendClosePrepared") ||
        pg_need((void **)&pg.PQtransactionStatus, "PQtransactionStatus") ||
        pg_need((void **)&pg.PQflush, "PQflush") ||
        pg_need((void **)&pg.PQconsumeInput, "PQconsumeInput") ||
        pg_need((void **)&pg.PQisBusy, "PQisBusy") ||
        pg_need((void **)&pg.PQgetResult, "PQgetResult") ||
        pg_need((void **)&pg.PQresultStatus, "PQresultStatus") ||
        pg_need((void **)&pg.PQresultErrorField, "PQresultErrorField") ||
        pg_need((void **)&pg.PQntuples, "PQntuples") ||
        pg_need((void **)&pg.PQnfields, "PQnfields") ||
        pg_need((void **)&pg.PQgetvalue, "PQgetvalue") ||
        pg_need((void **)&pg.PQgetlength, "PQgetlength") ||
        pg_need((void **)&pg.PQgetisnull, "PQgetisnull") ||
        pg_need((void **)&pg.PQclear, "PQclear") ||
        pg_need((void **)&pg.PQsetChunkedRowsMode, "PQsetChunkedRowsMode") ||
        pg_need((void **)&pg.PQerrorMessage, "PQerrorMessage") ||
        pg_need((void **)&pg.PQfinish, "PQfinish") ||
        pg_need((void **)&pg.PQenterPipelineMode, "PQenterPipelineMode") ||
        pg_need((void **)&pg.PQexitPipelineMode, "PQexitPipelineMode") ||
        pg_need((void **)&pg.PQsendPipelineSync, "PQsendPipelineSync") ||
        pg_need((void **)&pg.PQsendFlushRequest, "PQsendFlushRequest") ||
        pg_need((void **)&pg.PQpipelineStatus, "PQpipelineStatus") ||
        pg_need((void **)&pg.PQsslInUse, "PQsslInUse") ||
        pg_need((void **)&pg.PQcancelCreate, "PQcancelCreate") ||
        pg_need((void **)&pg.PQcancelStart, "PQcancelStart") ||
        pg_need((void **)&pg.PQcancelPoll, "PQcancelPoll") ||
        pg_need((void **)&pg.PQcancelSocket, "PQcancelSocket") ||
        pg_need((void **)&pg.PQcancelFinish, "PQcancelFinish") ||
        pg_need((void **)&pg.PQsetNoticeProcessor, "PQsetNoticeProcessor") ||
        pg_need((void **)&pg.PQftype, "PQftype") ||
        pg_need((void **)&pg.PQresultErrorMessage, "PQresultErrorMessage") ||
        pg_need((void **)&pg.PQunescapeBytea, "PQunescapeBytea") ||
        pg_need((void **)&pg.PQfreemem, "PQfreemem")) {
        return -1;
    }
    return 0;
}

static void *pg_open(void) {
    const char *env = getenv("KILN_LIBPQ");
    int i;
    if (env && env[0]) {
        return dlopen(env, RTLD_NOW | RTLD_LOCAL);
    }
    for (i = 0; pg_names[i]; i++) {
        void *handle = dlopen(pg_names[i], RTLD_NOW | RTLD_LOCAL);
        if (handle) {
            return handle;
        }
    }
    return NULL;
}

static int pg_step(kiln_db_conn *conn, int ready_bits, int64_t deadline_ms);
static void pg_release(kiln_db_conn *conn);

static int pg_load_now(void) {
    pg_lib = pg_open();
    if (!pg_lib) {
        kiln_db_set_load_error("libpq");
        return KILN_DB_CONN;
    }
    if (pg_bind() != 0) {
        dlclose(pg_lib);
        pg_lib = NULL;
        return KILN_DB_CONN;
    }
    pg_version = pg.PQlibVersion();
    if (pg_version < 170000) {
        kiln_db_set_load_error("PQlibVersion");
        dlclose(pg_lib);
        pg_lib = NULL;
        pg_version = 0;
        return KILN_DB_CONN;
    }
    kiln_db_driver_register(KILN_DB_KIND_PG, pg_step, pg_release);
    kiln_db_set_load_error(NULL);
    return KILN_DB_OK;
}

int kiln_db_pg_load(void) {
    int rc;
    pthread_mutex_lock(&pg_mu);
    if (pg_loaded) {
        rc = pg_load_rc;
        pthread_mutex_unlock(&pg_mu);
        return rc;
    }
    rc = pg_load_now();
    pg_load_rc = rc;
    if (rc == KILN_DB_OK) {
        pg_loaded = 1;
    }
    pthread_mutex_unlock(&pg_mu);
    return rc;
}

long kiln_db_pg_client_version(void) {
    if (kiln_db_pg_load() != KILN_DB_OK) {
        return 0;
    }
    return pg_version;
}

static pg_sess *pg_session(kiln_db_conn *conn) {
    if (!conn->native) {
        pg_sess *sess = calloc(1, sizeof *sess);
        if (!sess) {
            return NULL;
        }
        conn->native = sess;
        conn->fd = -1;
    }
    return conn->native;
}

static int pg_fail(kiln_db_conn *conn, int code, const char *state, const char *message) {
    kiln_db_fail(conn, code, 0, state, message ? message : "");
    return KILN_DB_STEP_ERR;
}

static int pg_wait(kiln_db_conn *conn, int fd, int kind) {
    conn->fd = fd;
    conn->wait_kind = kind;
    conn->wait_ms = fd < 0 ? 10 : 0;
    if (fd < 0) {
        conn->wait_kind = KILN_DB_READY_TIMEOUT;
    }
    return KILN_DB_STEP_WAIT;
}

static int pg_yield(kiln_db_conn *conn) {
    conn->fd = -1;
    conn->wait_kind = KILN_DB_READY_TIMEOUT;
    conn->wait_ms = 1;
    return KILN_DB_STEP_WAIT;
}

static void pg_clear_params(pg_sess *sess) {
    int i;
    for (i = 0; i < sess->nparams && i < sess->pcap; i++) {
        free(sess->values[i]);
        sess->values[i] = NULL;
        sess->lengths[i] = 0;
        sess->formats[i] = 0;
    }
    sess->nparams = 0;
}

static int pg_reserve_params(pg_sess *sess, int want) {
    int cap = sess->pcap ? sess->pcap : 16;
    char **values;
    int *lengths;
    int *formats;
    if (want <= sess->pcap) {
        return KILN_DB_OK;
    }
    while (cap < want) {
        cap *= 2;
    }
    if (cap > KILN_DB_MAX_PARAMS) {
        cap = KILN_DB_MAX_PARAMS;
    }
    values = realloc(sess->values, (size_t)cap * sizeof *values);
    if (!values) {
        return KILN_DB_CAPACITY;
    }
    sess->values = values;
    lengths = realloc(sess->lengths, (size_t)cap * sizeof *lengths);
    if (!lengths) {
        return KILN_DB_CAPACITY;
    }
    sess->lengths = lengths;
    formats = realloc(sess->formats, (size_t)cap * sizeof *formats);
    if (!formats) {
        return KILN_DB_CAPACITY;
    }
    sess->formats = formats;
    memset(values + sess->pcap, 0, (size_t)(cap - sess->pcap) * sizeof *values);
    memset(lengths + sess->pcap, 0, (size_t)(cap - sess->pcap) * sizeof *lengths);
    memset(formats + sess->pcap, 0, (size_t)(cap - sess->pcap) * sizeof *formats);
    sess->pcap = cap;
    return KILN_DB_OK;
}

static int pg_numeric(const char *host) {
    unsigned char raw[16];
    if (!host || !host[0]) {
        return 0;
    }
    return inet_pton(AF_INET, host, raw) == 1 || inet_pton(AF_INET6, host, raw) == 1;
}

int kiln_db_pg_bind_str(
    kiln_db_conn *conn, uint32_t index, const char *data, long n, int is_null, int format) {
    pg_sess *sess = pg_session(conn);
    const kiln_db_limits *limits = kiln_db_limits_get();
    char *copy;
    if (!sess || !limits) {
        return KILN_DB_CAPACITY;
    }
    if (index >= KILN_DB_MAX_PARAMS || n < 0 || (uint64_t)n > limits->max_payload_bytes ||
        (!is_null && n > 0 && !data)) {
        return KILN_DB_CAPACITY;
    }
    if (sess->bind_phase != conn->setup_phase) {
        pg_clear_params(sess);
        sess->bind_phase = conn->setup_phase;
    }
    if (pg_reserve_params(sess, (int)index + 1) != KILN_DB_OK) {
        return KILN_DB_CAPACITY;
    }
    while (sess->nparams < (int)index + 1) {
        sess->values[sess->nparams] = NULL;
        sess->lengths[sess->nparams] = 0;
        sess->formats[sess->nparams] = 0;
        sess->nparams++;
    }
    free(sess->values[index]);
    sess->values[index] = NULL;
    sess->lengths[index] = 0;
    sess->formats[index] = format ? 1 : 0;
    if (!is_null) {
        copy = malloc((size_t)n + 1u);
        if (!copy) {
            return KILN_DB_CAPACITY;
        }
        if (n > 0) {
            memcpy(copy, data, (size_t)n);
        }
        copy[n] = 0;
        sess->values[index] = copy;
        sess->lengths[index] = (int)n;
    }
    return KILN_DB_OK;
}

int kiln_db_pg_result_meta(kiln_db_conn *conn, int64_t *out, int n) {
    pg_sess *sess = conn->native;
    if (!out || n < 5) {
        return KILN_DB_ERR;
    }
    out[0] = 0;
    out[1] = 0;
    out[2] = conn->fetch_done ? 1 : 0;
    out[3] = conn->rows_affected;
    out[4] = sess && sess->sync_mark ? 1 : 0;
    if (!sess || !sess->held) {
        return KILN_DB_OK;
    }
    out[0] = pg.PQnfields(sess->held);
    out[1] = pg.PQntuples(sess->held);
    out[2] = conn->fetch_done ? 1 : 0;
    return KILN_DB_OK;
}

const char *kiln_db_pg_result_bytes(
    kiln_db_conn *conn, uint32_t row, uint32_t col, int64_t *meta, int meta_n) {
    static __thread char empty[1];
    pg_sess *sess = conn->native;
    const char *view = "";
    int is_null = 1;
    int length = 0;
    int rc;
    empty[0] = 0;
    if (meta && meta_n > 0) {
        meta[0] = 1;
    }
    if (meta && meta_n > 1) {
        meta[1] = 0;
    }
    if (!sess || !sess->held) {
        sp_ffi_bin_len = 0;
        return empty;
    }
    if ((int)row >= pg.PQntuples(sess->held) || (int)col >= pg.PQnfields(sess->held)) {
        sp_ffi_bin_len = 0;
        return empty;
    }
    rc = kiln_db_pg_field(pg.PQgetvalue(sess->held, (int)row, (int)col),
        pg.PQgetlength(sess->held, (int)row, (int)col),
        pg.PQgetisnull(sess->held, (int)row, (int)col), &is_null, &view, &length);
    if (rc != KILN_DB_OK) {
        sp_ffi_bin_len = 0;
        return empty;
    }
    if (meta && meta_n > 0) {
        meta[0] = is_null;
    }
    if (meta && meta_n > 1) {
        meta[1] = length;
    }
    sp_ffi_bin_len = length;
    return view ? view : empty;
}

static int pg_state_code(const char *state) {
    if (strcmp(state, "23505") == 0) {
        return KILN_DB_UNIQUE;
    }
    if (strcmp(state, "23503") == 0) {
        return KILN_DB_FK;
    }
    if (strcmp(state, "23502") == 0) {
        return KILN_DB_NOTNULL;
    }
    if (strcmp(state, "23514") == 0) {
        return KILN_DB_CHECK;
    }
    if (strcmp(state, "40P01") == 0) {
        return KILN_DB_DEADLOCK;
    }
    if (strcmp(state, "40001") == 0) {
        return KILN_DB_SERIAL;
    }
    if (strcmp(state, "55P03") == 0) {
        return KILN_DB_LOCKWAIT;
    }
    return KILN_DB_ERR;
}

static void pg_note_fatal(pg_sess *sess, kiln_db_conn *conn, PGresult *res) {
    const char *state = pg.PQresultErrorField(res, PG_DIAG_SQLSTATE);
    const char *message = pg.PQresultErrorMessage(res);
    if (!message || !message[0]) {
        message = pg.PQerrorMessage(sess->pg);
    }
    memset(sess->fatal_state, 0, sizeof sess->fatal_state);
    if (state) {
        size_t i;
        for (i = 0; i < 5 && state[i]; i++) {
            sess->fatal_state[i] = state[i];
        }
    }
    snprintf(sess->fatal_message, sizeof sess->fatal_message, "%s %s", sess->fatal_state,
        message ? message : "postgres error");
    sess->fatal = 1;
    sess->fatal_code = pg_state_code(sess->fatal_state);
    kiln_db_fail(conn, sess->fatal_code, 0, sess->fatal_state, sess->fatal_message);
}

static int pg_params(pg_sess *sess, conn_params *p);

static uint64_t pg_hash(const char *sql, size_t len) {
    uint64_t h = 14695981039346656037ull;
    size_t i;
    for (i = 0; i < len; i++) {
        h ^= (unsigned char)sql[i];
        h *= 1099511628211ull;
    }
    return h ? h : 1;
}

static int pg_starts(const char *sql, const char *word) {
    size_t n = strlen(word);
    while (*sql == ' ' || *sql == '\t' || *sql == '\n' || *sql == '\r') {
        sql++;
    }
    if (strncasecmp(sql, word, n) != 0) {
        return 0;
    }
    return sql[n] == 0 || sql[n] == ' ' || sql[n] == '\t' || sql[n] == '\n' || sql[n] == '\r' ||
           sql[n] == ';';
}

static int pg_drops_names(const char *sql) {
    return pg_starts(sql, "DEALLOCATE") || pg_starts(sql, "DISCARD");
}

static int pg_changes_schema(const char *sql) {
    return pg_starts(sql, "ALTER") || pg_starts(sql, "CREATE") || pg_starts(sql, "DROP") ||
           pg_starts(sql, "TRUNCATE");
}

static int pg_seen(const pg_sess *sess, uint64_t hash) {
    int i;
    for (i = 0; i < PG_SEEN; i++) {
        if (sess->seen[i] == hash) {
            return 1;
        }
    }
    return 0;
}

static void pg_remember(pg_sess *sess, uint64_t hash) {
    sess->seen[sess->seen_at] = hash;
    sess->seen_at = (sess->seen_at + 1) % PG_SEEN;
}

static void pg_ent_clear(pg_sess *sess, pg_stmt_ent *ent) {
    if (ent->sql && sess->cache_used > 0) {
        sess->cache_used--;
    }
    free(ent->sql);
    memset(ent, 0, sizeof *ent);
}

static void pg_cache_drop_all(pg_sess *sess) {
    int i;
    for (i = 0; i < sess->cache_cap; i++) {
        pg_ent_clear(sess, &sess->cache[i]);
    }
    sess->cache_used = 0;
    sess->close_n = 0;
}

static void pg_cache_stale_all(pg_sess *sess) {
    int i;
    for (i = 0; i < sess->cache_cap; i++) {
        if (sess->cache[i].sql) {
            sess->cache[i].stale = 1;
        }
    }
}

static int pg_cache_ready(pg_sess *sess, const kiln_db_conn *conn) {
    int cap = conn->stmt_cache;
    if (cap <= 0) {
        return sess->cache_cap > 0;
    }
    if (cap > 256) {
        cap = 256;
    }
    if (!sess->cache) {
        sess->cache = calloc((size_t)cap, sizeof *sess->cache);
        if (!sess->cache) {
            return 0;
        }
        sess->cache_cap = cap;
    }
    return 1;
}

static pg_stmt_ent *pg_cache_find(pg_sess *sess, uint64_t hash, const char *sql, size_t len) {
    int i;
    for (i = 0; i < sess->cache_cap; i++) {
        pg_stmt_ent *ent = &sess->cache[i];
        if (ent->sql && ent->hash == hash && ent->len == len && memcmp(ent->sql, sql, len) == 0) {
            return ent;
        }
    }
    return NULL;
}

static pg_stmt_ent *pg_cache_by_name(pg_sess *sess, const char *name) {
    int i;
    for (i = 0; i < sess->cache_cap; i++) {
        if (sess->cache[i].sql && strcmp(sess->cache[i].name, name) == 0) {
            return &sess->cache[i];
        }
    }
    return NULL;
}

static int pg_queue_close(pg_sess *sess, const char *name) {
    if (sess->close_n >= PG_CLOSE_MAX) {
        return 0;
    }
    snprintf(sess->close_q[sess->close_n], PG_NAME_MAX, "%s", name);
    sess->close_n++;
    return 1;
}

static int pg_cache_retire(pg_sess *sess, pg_stmt_ent *ent) {
    if (!pg_queue_close(sess, ent->name)) {
        return 0;
    }
    pg_ent_clear(sess, ent);
    return 1;
}

static int pg_cache_room(pg_sess *sess) {
    pg_stmt_ent *victim = NULL;
    int i;
    if (sess->cache_used < sess->cache_cap) {
        return 1;
    }
    for (i = 0; i < sess->cache_cap; i++) {
        pg_stmt_ent *ent = &sess->cache[i];
        if (ent->sql && (!victim || ent->stamp < victim->stamp)) {
            victim = ent;
        }
    }
    return victim && pg_cache_retire(sess, victim);
}

static int pg_cache_insert(pg_sess *sess, const kiln_db_conn *conn) {
    int i;
    for (i = 0; i < sess->cache_cap; i++) {
        pg_stmt_ent *ent = &sess->cache[i];
        if (ent->sql) {
            continue;
        }
        ent->sql = malloc(conn->sql_len + 1);
        if (!ent->sql) {
            return 0;
        }
        memcpy(ent->sql, conn->sql, conn->sql_len);
        ent->sql[conn->sql_len] = 0;
        ent->len = conn->sql_len;
        ent->hash = sess->pend_hash;
        ent->stamp = ++sess->cache_clock;
        ent->stale = 0;
        snprintf(ent->name, PG_NAME_MAX, "%s", sess->pend_name);
        sess->cache_used++;
        return 1;
    }
    return 0;
}

static int pg_chunk_mode(pg_sess *sess, const kiln_db_conn *conn) {
    return conn->ready_hint <= 0 || pg.PQsetChunkedRowsMode(sess->pg, conn->ready_hint) == 1;
}

static int pg_send_plain(pg_sess *sess, kiln_db_conn *conn) {
    conn_params p = {0, NULL, NULL, NULL};
    int count = 0;
    if (sess->bind_phase == conn->setup_phase) {
        count = pg_params(sess, &p);
    }
    if (pg.PQsendQueryParams(sess->pg, conn->sql, count, NULL, count ? p.values : NULL,
            count ? p.lengths : NULL, count ? p.formats : NULL, conn->result_format) != 1) {
        return 0;
    }
    return pg_chunk_mode(sess, conn);
}

static int pg_send_named(pg_sess *sess, kiln_db_conn *conn, const char *name) {
    conn_params p = {0, NULL, NULL, NULL};
    int count = 0;
    if (sess->bind_phase == conn->setup_phase) {
        count = pg_params(sess, &p);
    }
    if (pg.PQsendQueryPrepared(sess->pg, name, count, count ? p.values : NULL,
            count ? p.lengths : NULL, count ? p.formats : NULL, conn->result_format) != 1) {
        return 0;
    }
    return pg_chunk_mode(sess, conn);
}

static int pg_cache_next(pg_sess *sess, kiln_db_conn *conn) {
    if (sess->close_n > 0) {
        sess->close_n--;
        snprintf(sess->run_name, PG_NAME_MAX, "%s", sess->close_q[sess->close_n]);
        sess->cstage = PG_C_CLOSE;
        return pg.PQsendClosePrepared(sess->pg, sess->run_name) == 1;
    }
    if (sess->cnext == PG_N_PREPARE) {
        sess->cnext = PG_N_PLAIN;
        sess->cstage = PG_C_PREPARE;
        return pg.PQsendPrepare(sess->pg, sess->pend_name, conn->sql, 0, NULL) == 1;
    }
    sess->cstage = sess->creset ? PG_C_PLAIN : PG_C_RETRY;
    return pg_send_plain(sess, conn);
}

static void pg_clear_fatal(pg_sess *sess, kiln_db_conn *conn) {
    sess->fatal = 0;
    sess->settle = 0;
    conn->err = KILN_DB_OK;
    conn->vendor_errno = 0;
    memset(conn->sqlstate, 0, sizeof conn->sqlstate);
}

static void pg_cache_settled(pg_sess *sess, const kiln_db_conn *conn) {
    if (sess->fatal || !sess->cache) {
        return;
    }
    if (sess->creset || pg_drops_names(conn->sql)) {
        pg_cache_drop_all(sess);
    } else if (pg_changes_schema(conn->sql)) {
        pg_cache_stale_all(sess);
    }
}

static int pg_cache_stale_error(pg_sess *sess, kiln_db_conn *conn) {
    pg_stmt_ent *ent = pg_cache_by_name(sess, sess->run_name);
    if (strcmp(sess->fatal_state, "26000") == 0) {
        pg_cache_drop_all(sess);
    } else if (strcmp(sess->fatal_state, "0A000") == 0) {
        if (ent && !pg_cache_retire(sess, ent)) {
            pg_ent_clear(sess, ent);
        }
    } else {
        return PG_DONE;
    }
    if (!sess->cretry) {
        return PG_DONE;
    }
    pg_clear_fatal(sess, conn);
    sess->cstage = PG_C_RETRY;
    if (!pg_send_plain(sess, conn)) {
        return pg_fail(conn, KILN_DB_CONN, NULL, pg.PQerrorMessage(sess->pg));
    }
    return PG_GO;
}

static int pg_cache_after(pg_sess *sess, kiln_db_conn *conn) {
    int stage = sess->cstage;
    sess->cstage = PG_C_NONE;
    if (conn->op == KILN_DB_OP_CANCEL) {
        if (stage == PG_C_PREPARE && !sess->fatal) {
            pg_queue_close(sess, sess->pend_name);
        }
        sess->cnext = PG_N_PLAIN;
        return PG_DONE;
    }
    if (stage == PG_C_CLOSE || (stage == PG_C_PREPARE && !sess->fatal)) {
        if (sess->fatal) {
            sess->cnext = PG_N_PLAIN;
            return PG_DONE;
        }
        if (stage == PG_C_PREPARE) {
            if (!pg_cache_insert(sess, conn)) {
                pg_queue_close(sess, sess->pend_name);
                sess->cstage = PG_C_RETRY;
                return pg_send_plain(sess, conn)
                           ? PG_GO
                           : pg_fail(conn, KILN_DB_CONN, NULL, pg.PQerrorMessage(sess->pg));
            }
            snprintf(sess->run_name, PG_NAME_MAX, "%s", sess->pend_name);
            sess->cstage = PG_C_EXEC;
            return pg_send_named(sess, conn, sess->run_name)
                       ? PG_GO
                       : pg_fail(conn, KILN_DB_CONN, NULL, pg.PQerrorMessage(sess->pg));
        }
        return pg_cache_next(sess, conn)
                   ? PG_GO
                   : pg_fail(conn, KILN_DB_CONN, NULL, pg.PQerrorMessage(sess->pg));
    }
    if (stage == PG_C_EXEC && sess->fatal) {
        return pg_cache_stale_error(sess, conn);
    }
    pg_cache_settled(sess, conn);
    return PG_DONE;
}

static int pg_cache_send(pg_sess *sess, kiln_db_conn *conn) {
    PGTransactionStatusType tx = pg.PQtransactionStatus(sess->pg);
    uint64_t hash = pg_hash(conn->sql, conn->sql_len);
    pg_stmt_ent *ent;
    sess->cretry = tx == PQTRANS_IDLE;
    sess->creset = pg_drops_names(conn->sql);
    sess->cnext = PG_N_PLAIN;
    if (tx != PQTRANS_IDLE && tx != PQTRANS_INTRANS) {
        sess->cstage = PG_C_RETRY;
        return pg_send_plain(sess, conn);
    }
    ent = sess->creset ? NULL : pg_cache_find(sess, hash, conn->sql, conn->sql_len);
    if (ent && !ent->stale) {
        ent->stamp = ++sess->cache_clock;
        snprintf(sess->run_name, PG_NAME_MAX, "%s", ent->name);
        sess->cstage = PG_C_EXEC;
        return pg_send_named(sess, conn, sess->run_name);
    }
    if (ent && !pg_cache_retire(sess, ent)) {
        return pg_cache_next(sess, conn);
    }
    if (!ent && (sess->creset || !pg_seen(sess, hash))) {
        pg_remember(sess, hash);
        return pg_cache_next(sess, conn);
    }
    if (!pg_cache_room(sess)) {
        return pg_cache_next(sess, conn);
    }
    sess->pend_hash = hash;
    sess->cache_serial++;
    snprintf(sess->pend_name, PG_NAME_MAX, "kiln_s%llu", (unsigned long long)sess->cache_serial);
    sess->cnext = PG_N_PREPARE;
    return pg_cache_next(sess, conn);
}

static int pg_pump(pg_sess *sess, kiln_db_conn *conn) {
    int fd = pg.PQsocket(sess->pg);
    sess->phase = 2;
    for (;;) {
        int flushed;
        PGresult *res;
        ExecStatusType status;
        if (sess->pump >= PG_PUMP_MAX) {
            sess->pump = 0;
            return pg_yield(conn);
        }
        sess->pump++;
        flushed = pg.PQflush(sess->pg);
        if (flushed < 0) {
            return pg_fail(conn, KILN_DB_CONN, NULL, pg.PQerrorMessage(sess->pg));
        }
        if (flushed == 1) {
            sess->pump = 0;
            return pg_wait(conn, fd, KILN_DB_READY_WRITE);
        }
        if (!pg.PQconsumeInput(sess->pg)) {
            return pg_fail(conn, KILN_DB_CONN, NULL, pg.PQerrorMessage(sess->pg));
        }
        if (pg.PQisBusy(sess->pg)) {
            sess->pump = 0;
            return pg_wait(conn, fd, KILN_DB_READY_READ);
        }
        res = pg.PQgetResult(sess->pg);
        if (!res && sess->cstage != PG_C_NONE) {
            int next = pg_cache_after(sess, conn);
            if (next == PG_GO) {
                continue;
            }
            if (next != PG_DONE) {
                sess->phase = 0;
                return next;
            }
        }
        if (!res) {
            sess->phase = 0;
            conn->fetch_done = 1;
            if (!sess->fatal && conn->op == KILN_DB_OP_PREPARE) {
                conn->prepared = 1;
            }
            if (sess->fatal) {
                int code = sess->fatal_code;
                int canceled =
                    conn->op == KILN_DB_OP_CANCEL && strcmp(sess->fatal_state, "57014") == 0;
                sess->fatal = 0;
                sess->settle = 0;
                if (canceled && pg.PQstatus(sess->pg) == CONNECTION_OK) {
                    conn->err = KILN_DB_OK;
                    conn->vendor_errno = 0;
                    memset(conn->sqlstate, 0, sizeof conn->sqlstate);
                    conn->wait_kind = 0;
                    conn->fd = fd;
                    return KILN_DB_STEP_DONE;
                }
                if (pg.PQstatus(sess->pg) != CONNECTION_OK) {
                    conn->broken = 1;
                }
                return pg_fail(conn, code, sess->fatal_state, sess->fatal_message);
            }
            sess->settle = 0;
            conn->wait_kind = 0;
            conn->fd = fd;
            return KILN_DB_STEP_DONE;
        }
        status = pg.PQresultStatus(res);
        if (status == PGRES_COMMAND_OK || status == PGRES_EMPTY_QUERY ||
            status == PGRES_PIPELINE_SYNC || status == PGRES_NONFATAL_ERROR) {
            pg.PQclear(res);
            continue;
        }
        if (status == PGRES_TUPLES_OK || status == PGRES_SINGLE_TUPLE ||
            status == PGRES_TUPLES_CHUNK) {
            PGresult *tail;
            ExecStatusType tail_status;
            if (sess->held) {
                pg.PQclear(sess->held);
            }
            sess->held = res;
            conn->fd = fd;
            conn->wait_kind = 0;
            if (status != PGRES_TUPLES_OK) {
                conn->fetch_done = 0;
                sess->phase = 4;
                return KILN_DB_STEP_DONE;
            }
            if (pg.PQisBusy(sess->pg)) {
                if (!pg.PQconsumeInput(sess->pg)) {
                    return pg_fail(conn, KILN_DB_CONN, NULL, pg.PQerrorMessage(sess->pg));
                }
                if (pg.PQisBusy(sess->pg)) {
                    sess->phase = 2;
                    sess->pump = 0;
                    return pg_wait(conn, fd, KILN_DB_READY_READ);
                }
            }
            tail = pg.PQgetResult(sess->pg);
            if (!tail) {
                sess->cstage = PG_C_NONE;
                conn->fetch_done = 1;
                sess->settle = 0;
                sess->phase = 4;
                return KILN_DB_STEP_DONE;
            }
            tail_status = pg.PQresultStatus(tail);
            if (tail_status == PGRES_FATAL_ERROR || tail_status == PGRES_BAD_RESPONSE ||
                tail_status == PGRES_PIPELINE_ABORTED) {
                pg_note_fatal(sess, conn, tail);
                pg.PQclear(tail);
                continue;
            }
            pg.PQclear(tail);
            return pg_fail(conn, KILN_DB_UNSUPPORTED, NULL, "multiple postgres results");
        }
        if (status == PGRES_FATAL_ERROR || status == PGRES_BAD_RESPONSE ||
            status == PGRES_PIPELINE_ABORTED) {
            pg_note_fatal(sess, conn, res);
            pg.PQclear(res);
            continue;
        }
        pg.PQclear(res);
        return pg_fail(conn, KILN_DB_UNSUPPORTED, NULL, "unexpected postgres result");
    }
}

static int pg_params(pg_sess *sess, conn_params *p) {
    p->count = sess->nparams;
    p->values = (const char *const *)sess->values;
    p->lengths = sess->lengths;
    p->formats = sess->formats;
    return p->count;
}

static int pg_send(pg_sess *sess, kiln_db_conn *conn) {
    const char *sql = conn->sql;
    conn_params p = {0, NULL, NULL, NULL};
    int count = 0;
    int rc;
    if (sess->held) {
        pg.PQclear(sess->held);
        sess->held = NULL;
    }
    sess->fatal = 0;
    sess->settle = 0;
    conn->fetch_done = 0;
    if (conn->op == KILN_DB_OP_BEGIN) {
        sql = "BEGIN";
    } else if (conn->op == KILN_DB_OP_COMMIT) {
        sql = "COMMIT";
    } else if (conn->op == KILN_DB_OP_ROLLBACK) {
        sql = "ROLLBACK";
    }
    if (!sql) {
        return pg_fail(conn, KILN_DB_CONFIG, NULL, "missing sql");
    }
    sess->cstage = PG_C_NONE;
    if (conn->op == KILN_DB_OP_EXEC && !conn->prepared && pg_cache_ready(sess, conn)) {
        if (!pg_cache_send(sess, conn)) {
            sess->cstage = PG_C_NONE;
            return pg_fail(conn, KILN_DB_CONN, NULL, pg.PQerrorMessage(sess->pg));
        }
        sess->pump = 0;
        return pg_pump(sess, conn);
    }
    if (conn->op == KILN_DB_OP_PREPARE) {
        rc = pg.PQsendPrepare(sess->pg, "", sql, 0, NULL);
    } else if (conn->op == KILN_DB_OP_EXEC && conn->prepared) {
        if (sess->bind_phase == conn->setup_phase) {
            count = pg_params(sess, &p);
        }
        rc = pg.PQsendQueryPrepared(sess->pg, "", count, count ? p.values : NULL,
            count ? p.lengths : NULL, count ? p.formats : NULL, conn->result_format);
    } else {
        if (conn->op == KILN_DB_OP_EXEC && sess->bind_phase == conn->setup_phase) {
            count = pg_params(sess, &p);
        }
        rc = pg.PQsendQueryParams(sess->pg, sql, count, NULL, count ? p.values : NULL,
            count ? p.lengths : NULL, count ? p.formats : NULL, conn->result_format);
    }
    if (rc != 1) {
        return pg_fail(conn, KILN_DB_CONN, NULL, pg.PQerrorMessage(sess->pg));
    }
    if (conn->op != KILN_DB_OP_PREPARE && conn->ready_hint > 0) {
        if (pg.PQsetChunkedRowsMode(sess->pg, conn->ready_hint) != 1) {
            return pg_fail(conn, KILN_DB_CONN, NULL, pg.PQerrorMessage(sess->pg));
        }
    }
    sess->pump = 0;
    return pg_pump(sess, conn);
}

static void pg_notice(void *arg, const char *message) {
    pg_sess *sess = arg;
    (void)message;
    if (sess) {
        sess->notices++;
    }
}

static const char *pg_host_list(pg_sess *sess, const char *host, const char *addrs) {
    size_t count = 1;
    size_t len = strlen(host);
    size_t used = 0;
    const char *it;
    size_t i;
    char *list;
    for (it = addrs; *it; it++) {
        count += *it == ',';
    }
    if (count == 1) {
        return host;
    }
    if (len > (SIZE_MAX / count) - 1) {
        return NULL;
    }
    list = malloc(count * (len + 1));
    if (!list) {
        return NULL;
    }
    for (i = 0; i < count; i++) {
        if (i) {
            list[used++] = ',';
        }
        memcpy(list + used, host, len);
        used += len;
    }
    list[used] = 0;
    free(sess->host_list);
    sess->host_list = list;
    return list;
}

static int pg_connect(pg_sess *sess, kiln_db_conn *conn) {
    PostgresPollingStatusType polled;
    if (!sess->pg) {
        const char *pq_host;
        const char *pq_addr = NULL;
        int n = 0;
        if (conn->ssl_mode == KILN_DB_SSL_VERIFY_FULL) {
            pq_host = conn->tls_name;
        } else {
            pq_host = conn->host;
        }
        if (!pq_host || !pq_host[0]) {
            return pg_fail(conn, KILN_DB_CONFIG, NULL, "missing host");
        }
        if (strchr(pq_host, ',')) {
            return pg_fail(conn, KILN_DB_CONFIG, NULL, "host must be a single name");
        }
        if (conn->hostaddr && conn->hostaddr[0]) {
            pq_addr = conn->hostaddr;
            pq_host = pg_host_list(sess, pq_host, pq_addr);
            if (!pq_host) {
                return pg_fail(conn, KILN_DB_CAPACITY, NULL, "host list");
            }
        } else if (conn->host && pg_numeric(conn->host)) {
            pq_addr = conn->host;
        }
        snprintf(sess->port_text, sizeof sess->port_text, "%d", conn->port);
        sess->keys[n] = "host";
        sess->vals[n] = pq_host;
        n++;
        if (pq_addr) {
            sess->keys[n] = "hostaddr";
            sess->vals[n] = pq_addr;
            n++;
        }
        sess->keys[n] = "port";
        sess->vals[n] = sess->port_text;
        n++;
        sess->keys[n] = "user";
        sess->vals[n] = conn->user ? conn->user : "";
        n++;
        sess->keys[n] = "password";
        sess->vals[n] = conn->pass ? conn->pass : "";
        n++;
        sess->keys[n] = "dbname";
        sess->vals[n] = conn->database ? conn->database : "";
        n++;
        if (conn->ssl_mode == KILN_DB_SSL_DISABLE) {
            sess->keys[n] = "sslmode";
            sess->vals[n] = "disable";
            n++;
        } else {
            sess->keys[n] = "sslmode";
            sess->vals[n] = "verify-full";
            n++;
            sess->keys[n] = "sslrootcert";
            sess->vals[n] = conn->ca_path ? conn->ca_path : "";
            n++;
        }
        sess->keys[n] = NULL;
        sess->vals[n] = NULL;
        sess->pg = pg.PQconnectStartParams(sess->keys, sess->vals, 0);
        if (!sess->pg) {
            return pg_fail(conn, KILN_DB_CONN, NULL, "PQconnectStartParams");
        }
    }
    polled = pg.PQconnectPoll(sess->pg);
    conn->fd = pg.PQsocket(sess->pg);
    if (polled == PGRES_POLLING_READING) {
        return pg_wait(conn, conn->fd, KILN_DB_READY_READ);
    }
    if (polled == PGRES_POLLING_WRITING) {
        return pg_wait(conn, conn->fd, KILN_DB_READY_WRITE);
    }
    if (polled != PGRES_POLLING_OK) {
        return pg_fail(conn, KILN_DB_CONN, NULL, pg.PQerrorMessage(sess->pg));
    }
    if (pg.PQsetnonblocking(sess->pg, 1) != 0 || pg.PQstatus(sess->pg) != CONNECTION_OK) {
        return pg_fail(conn, KILN_DB_CONN, NULL, pg.PQerrorMessage(sess->pg));
    }
    if (conn->ssl_mode == KILN_DB_SSL_VERIFY_FULL && !pg.PQsslInUse(sess->pg)) {
        return pg_fail(conn, KILN_DB_CONN, NULL, "tls required");
    }
    pg.PQsetNoticeProcessor(sess->pg, pg_notice, sess);
    conn->fd = pg.PQsocket(sess->pg);
    conn->wait_kind = 0;
    return KILN_DB_STEP_DONE;
}

static int pg_cancel(pg_sess *sess, kiln_db_conn *conn) {
    PostgresPollingStatusType polled;
    int fd;
    if (!sess->pg) {
        return pg_fail(conn, KILN_DB_CONN, NULL, "cancel without connection");
    }
    if (!sess->cancel) {
        sess->cancel = pg.PQcancelCreate(sess->pg);
        if (!sess->cancel || !pg.PQcancelStart(sess->cancel)) {
            if (sess->cancel) {
                pg.PQcancelFinish(sess->cancel);
                sess->cancel = NULL;
            }
            return pg_fail(conn, KILN_DB_CONN, NULL, pg.PQerrorMessage(sess->pg));
        }
    }
    polled = pg.PQcancelPoll(sess->cancel);
    fd = pg.PQcancelSocket(sess->cancel);
    if (polled == PGRES_POLLING_READING || polled == PGRES_POLLING_WRITING) {
        return pg_wait(
            conn, fd, polled == PGRES_POLLING_WRITING ? KILN_DB_READY_WRITE : KILN_DB_READY_READ);
    }
    pg.PQcancelFinish(sess->cancel);
    sess->cancel = NULL;
    if (sess->held) {
        pg.PQclear(sess->held);
        sess->held = NULL;
    }
    sess->settle = 1;
    sess->pump = 0;
    return pg_pump(sess, conn);
}

static int pg_pipe_idle(pg_sess *sess) {
    return sess->phase == 0 || sess->phase == 4;
}

static int pg_pipe_flush(pg_sess *sess, kiln_db_conn *conn) {
    int fd = pg.PQsocket(sess->pg);
    int flushed;
    if (sess->pump >= PG_PUMP_MAX) {
        sess->pump = 0;
        sess->phase = 5;
        return pg_wait(conn, fd, KILN_DB_READY_WRITE);
    }
    sess->pump++;
    flushed = pg.PQflush(sess->pg);
    if (flushed < 0) {
        sess->phase = 0;
        conn->broken = 1;
        return pg_fail(conn, KILN_DB_CONN, NULL, pg.PQerrorMessage(sess->pg));
    }
    if (flushed == 1) {
        sess->pump = 0;
        sess->phase = 5;
        return pg_wait(conn, fd, KILN_DB_READY_WRITE);
    }
    sess->phase = 0;
    sess->pump = 0;
    conn->wait_kind = 0;
    conn->fd = fd;
    return KILN_DB_STEP_DONE;
}

static int pg_pipe_send(pg_sess *sess, kiln_db_conn *conn, int sync) {
    const kiln_db_limits *limits;
    conn_params p = {0, NULL, NULL, NULL};
    uint32_t cap;
    int count = 0;
    int rc;
    if (!sess->pipeline) {
        return pg_fail(conn, KILN_DB_CONFIG, NULL, "pipeline");
    }
    if (sess->phase == 5) {
        return pg_pipe_flush(sess, conn);
    }
    if (!pg_pipe_idle(sess)) {
        return pg_fail(conn, KILN_DB_CONFIG, NULL, "pipeline busy");
    }
    limits = kiln_db_limits_get();
    cap = limits && limits->max_pipeline_inflight ? limits->max_pipeline_inflight : 64u;
    if ((uint32_t)sess->inflight >= cap) {
        return pg_fail(conn, KILN_DB_CAPACITY, NULL, "pipeline");
    }
    if (sess->held) {
        pg.PQclear(sess->held);
        sess->held = NULL;
    }
    if (sync) {
        rc = pg.PQsendPipelineSync(sess->pg);
    } else {
        if (sess->bind_phase == conn->setup_phase) {
            count = pg_params(sess, &p);
        }
        if (!conn->sql) {
            return pg_fail(conn, KILN_DB_CONFIG, NULL, "missing sql");
        }
        rc = pg.PQsendQueryParams(sess->pg, conn->sql, count, NULL, count ? p.values : NULL,
            count ? p.lengths : NULL, count ? p.formats : NULL, conn->result_format);
    }
    if (rc != 1 || pg.PQsendFlushRequest(sess->pg) != 1) {
        conn->broken = 1;
        return pg_fail(conn, KILN_DB_CONN, NULL, pg.PQerrorMessage(sess->pg));
    }
    sess->inflight++;
    sess->sync_mark = 0;
    sess->pump = 0;
    return pg_pipe_flush(sess, conn);
}

static int pg_pipe_finish(pg_sess *sess, kiln_db_conn *conn, int fd) {
    if (sess->inflight > 0) {
        sess->inflight--;
    }
    sess->phase = 0;
    sess->hold_tail = 0;
    sess->pump = 0;
    conn->fetch_done = 1;
    conn->wait_kind = 0;
    conn->fd = fd;
    if (sess->fatal) {
        int code = sess->fatal_code;
        sess->fatal = 0;
        if (pg.PQstatus(sess->pg) != CONNECTION_OK) {
            conn->broken = 1;
        }
        return pg_fail(conn, code, sess->fatal_state, sess->fatal_message);
    }
    return KILN_DB_STEP_DONE;
}

static void pg_mark_aborted(pg_sess *sess, kiln_db_conn *conn) {
    memset(sess->fatal_state, 0, sizeof sess->fatal_state);
    memcpy(sess->fatal_state, "PABRT", 5);
    snprintf(sess->fatal_message, sizeof sess->fatal_message, "PGRES_PIPELINE_ABORTED");
    sess->fatal = 1;
    sess->fatal_code = KILN_DB_ERR;
    kiln_db_fail(conn, KILN_DB_ERR, 0, sess->fatal_state, sess->fatal_message);
}

static int pg_pipeline_take(pg_sess *sess, kiln_db_conn *conn) {
    int fd = pg.PQsocket(sess->pg);
    if (!sess->pipeline) {
        return pg_fail(conn, KILN_DB_CONFIG, NULL, "pipeline");
    }
    if (sess->phase != 6) {
        if (sess->inflight <= 0) {
            return pg_fail(conn, KILN_DB_CONFIG, NULL, "pipeline empty");
        }
        sess->phase = 6;
        sess->pump = 0;
        sess->fatal = 0;
        sess->sync_mark = 0;
        sess->hold_tail = 0;
        conn->fetch_done = 0;
        if (sess->held) {
            pg.PQclear(sess->held);
            sess->held = NULL;
        }
    }
    for (;;) {
        PGresult *res;
        ExecStatusType status;
        if (sess->pump >= PG_PUMP_MAX) {
            sess->pump = 0;
            return pg_yield(conn);
        }
        sess->pump++;
        if (pg.PQflush(sess->pg) == 1) {
            sess->pump = 0;
            return pg_wait(conn, fd, KILN_DB_READY_WRITE);
        }
        if (!pg.PQconsumeInput(sess->pg)) {
            conn->broken = 1;
            return pg_fail(conn, KILN_DB_CONN, NULL, pg.PQerrorMessage(sess->pg));
        }
        if (pg.PQisBusy(sess->pg)) {
            sess->pump = 0;
            return pg_wait(conn, fd, KILN_DB_READY_READ);
        }
        res = pg.PQgetResult(sess->pg);
        if (!res) {
            return pg_pipe_finish(sess, conn, fd);
        }
        status = pg.PQresultStatus(res);
        if (status == PGRES_PIPELINE_SYNC) {
            pg.PQclear(res);
            sess->sync_mark = 1;
            conn->fetch_done = 1;
            if (sess->inflight == 1 && !pg.PQisBusy(sess->pg)) {
                PGresult *tail = pg.PQgetResult(sess->pg);
                if (tail) {
                    pg.PQclear(tail);
                    conn->broken = 1;
                    return pg_fail(conn, KILN_DB_CONN, NULL, "pipeline sync tail");
                }
            }
            return pg_pipe_finish(sess, conn, fd);
        }
        if (status == PGRES_TUPLES_OK || status == PGRES_SINGLE_TUPLE ||
            status == PGRES_TUPLES_CHUNK) {
            if (sess->held) {
                pg.PQclear(sess->held);
            }
            sess->held = res;
            sess->hold_tail = 1;
            continue;
        }
        if (status == PGRES_COMMAND_OK || status == PGRES_EMPTY_QUERY ||
            status == PGRES_NONFATAL_ERROR) {
            pg.PQclear(res);
            continue;
        }
        if (status == PGRES_PIPELINE_ABORTED) {
            pg_mark_aborted(sess, conn);
            pg.PQclear(res);
            sess->hold_tail = 0;
            continue;
        }
        if (status == PGRES_FATAL_ERROR || status == PGRES_BAD_RESPONSE) {
            pg_note_fatal(sess, conn, res);
            pg.PQclear(res);
            sess->hold_tail = 0;
            continue;
        }
        pg.PQclear(res);
        return pg_fail(conn, KILN_DB_UNSUPPORTED, NULL, "unexpected postgres result");
    }
}

static int pg_pipeline_enter(pg_sess *sess, kiln_db_conn *conn) {
    if (sess->pipeline || !pg_pipe_idle(sess) || pg.PQstatus(sess->pg) != CONNECTION_OK) {
        return pg_fail(conn, KILN_DB_CONFIG, NULL, "pipeline enter");
    }
    if (pg.PQpipelineStatus(sess->pg) != PQ_PIPELINE_OFF) {
        return pg_fail(conn, KILN_DB_CONFIG, NULL, "pipeline enter");
    }
    if (sess->held) {
        pg.PQclear(sess->held);
        sess->held = NULL;
    }
    if (pg.PQenterPipelineMode(sess->pg) != 1) {
        return pg_fail(conn, KILN_DB_CONN, NULL, pg.PQerrorMessage(sess->pg));
    }
    sess->pipeline = 1;
    sess->inflight = 0;
    sess->sync_mark = 0;
    sess->phase = 0;
    conn->in_pipeline = 1;
    conn->fetch_done = 1;
    conn->wait_kind = 0;
    return KILN_DB_STEP_DONE;
}

static int pg_pipeline_exit(pg_sess *sess, kiln_db_conn *conn) {
    if (!sess->pipeline) {
        conn->in_pipeline = 0;
        return KILN_DB_STEP_DONE;
    }
    if (sess->inflight != 0 || !pg_pipe_idle(sess)) {
        return pg_fail(conn, KILN_DB_CONFIG, NULL, "pipeline exit");
    }
    if (pg.PQexitPipelineMode(sess->pg) != 1) {
        conn->broken = 1;
        return pg_fail(conn, KILN_DB_CONN, NULL, pg.PQerrorMessage(sess->pg));
    }
    sess->pipeline = 0;
    sess->sync_mark = 0;
    conn->in_pipeline = 0;
    conn->wait_kind = 0;
    return KILN_DB_STEP_DONE;
}

static int pg_step(kiln_db_conn *conn, int ready_bits, int64_t deadline_ms) {
    pg_sess *sess;
    (void)ready_bits;
    (void)deadline_ms;
    sess = pg_session(conn);
    if (!sess) {
        return pg_fail(conn, KILN_DB_CAPACITY, NULL, "session");
    }
    if (!sess->pg && conn->op != KILN_DB_OP_CONNECT) {
        return pg_fail(conn, KILN_DB_CONN, NULL, "not connected");
    }
    if (conn->op == KILN_DB_OP_CONNECT) {
        return pg_connect(sess, conn);
    }
    if (conn->op == KILN_DB_OP_PIPELINE_ENTER) {
        return pg_pipeline_enter(sess, conn);
    }
    if (conn->op == KILN_DB_OP_PIPELINE_EXIT) {
        return pg_pipeline_exit(sess, conn);
    }
    if (conn->op == KILN_DB_OP_PIPELINE_QUERY) {
        return pg_pipe_send(sess, conn, 0);
    }
    if (conn->op == KILN_DB_OP_PIPELINE_SYNC) {
        return pg_pipe_send(sess, conn, 1);
    }
    if (conn->op == KILN_DB_OP_PIPELINE_TAKE) {
        return pg_pipeline_take(sess, conn);
    }
    if (sess->pipeline) {
        return pg_fail(conn, KILN_DB_UNSUPPORTED, NULL, "pipeline op");
    }
    if (conn->op == KILN_DB_OP_CANCEL) {
        if (sess->settle) {
            return pg_pump(sess, conn);
        }
        return pg_cancel(sess, conn);
    }
    if (conn->op == KILN_DB_OP_DRAIN) {
        if (sess->phase == 2) {
            return pg_pump(sess, conn);
        }
        if (sess->held) {
            pg.PQclear(sess->held);
            sess->held = NULL;
            sess->pump = 0;
            return pg_pump(sess, conn);
        }
        conn->fetch_done = 1;
        conn->wait_kind = 0;
        return KILN_DB_STEP_DONE;
    }
    if (conn->op == KILN_DB_OP_EXEC || conn->op == KILN_DB_OP_PREPARE ||
        conn->op == KILN_DB_OP_BEGIN || conn->op == KILN_DB_OP_COMMIT ||
        conn->op == KILN_DB_OP_ROLLBACK) {
        if (sess->phase == 2) {
            return pg_pump(sess, conn);
        }
        if (conn->op == KILN_DB_OP_PREPARE) {
            conn->prepared = 0;
        }
        return pg_send(sess, conn);
    }
    return pg_fail(conn, KILN_DB_UNSUPPORTED, NULL, "postgres op");
}

static void pg_release(kiln_db_conn *conn) {
    pg_sess *sess = conn->native;
    if (!sess) {
        return;
    }
    if (sess->cancel) {
        pg.PQcancelFinish(sess->cancel);
    }
    if (sess->held) {
        pg.PQclear(sess->held);
    }
    if (sess->pg) {
        pg.PQfinish(sess->pg);
    }
    pg_cache_drop_all(sess);
    free(sess->cache);
    pg_clear_params(sess);
    free(sess->values);
    free(sess->lengths);
    free(sess->formats);
    free(sess->host_list);
    free(sess);
    conn->native = NULL;
    conn->prepared = 0;
    conn->res = NULL;
    conn->cancel = NULL;
}

static int pg_type_code(Oid oid) {
    switch (oid) {
    case 16:
        return KILN_DB_T_BOOL;
    case 20:
    case 21:
    case 23:
    case 26:
        return KILN_DB_T_INT;
    case 700:
    case 701:
        return KILN_DB_T_FLOAT;
    case 1700:
        return KILN_DB_T_DECIMAL;
    case 17:
        return KILN_DB_T_BINARY;
    default:
        return KILN_DB_T_TEXT;
    }
}

int kiln_db_pg_result_types(kiln_db_conn *conn, int64_t *out, int n) {
    pg_sess *sess = conn->native;
    int cols;
    int i;
    if (!out || n < 0) {
        return KILN_DB_ERR;
    }
    if (!sess || !sess->held) {
        return KILN_DB_OK;
    }
    cols = pg.PQnfields(sess->held);
    for (i = 0; i < cols && i < n; i++) {
        out[i] = pg_type_code(pg.PQftype(sess->held, i));
    }
    return cols > n ? KILN_DB_CAPACITY : KILN_DB_OK;
}

const char *kiln_db_pg_result_row(kiln_db_conn *conn, uint32_t row, int64_t *lens, int n) {
    static __thread char empty[1];
    pg_sess *sess = conn->native;
    char *buf = NULL;
    size_t used = 0;
    int cols;
    int i;
    empty[0] = 0;
    sp_ffi_bin_len = 0;
    if (!sess || !sess->held || !lens || n <= 0 || (int)row >= pg.PQntuples(sess->held)) {
        if (lens && n > 0) {
            lens[0] = -2;
        }
        return empty;
    }
    cols = pg.PQnfields(sess->held);
    if (cols > n) {
        lens[0] = -2;
        return empty;
    }
    for (i = 0; i < cols; i++) {
        const char *value;
        size_t len;
        unsigned char *decoded = NULL;
        if (pg.PQgetisnull(sess->held, (int)row, i)) {
            lens[i] = -1;
            continue;
        }
        value = pg.PQgetvalue(sess->held, (int)row, i);
        len = (size_t)pg.PQgetlength(sess->held, (int)row, i);
        if (pg.PQftype(sess->held, i) == 17 && conn->result_format == 0) {
            decoded = pg.PQunescapeBytea((const unsigned char *)value, &len);
            if (!decoded) {
                lens[0] = -2;
                return empty;
            }
            value = (const char *)decoded;
        }
        if (used == SIZE_MAX || len > SIZE_MAX - used - 1 || len > INT_MAX) {
            if (decoded) {
                pg.PQfreemem(decoded);
            }
            lens[0] = -2;
            return empty;
        }
        buf = kiln_db_thread_room(used + len + 1);
        if (!buf) {
            if (decoded) {
                pg.PQfreemem(decoded);
            }
            lens[0] = -2;
            return empty;
        }
        if (len) {
            memcpy(buf + used, value, len);
        }
        if (decoded) {
            pg.PQfreemem(decoded);
        }
        lens[i] = (int64_t)len;
        used += len;
    }
    buf = used <= INT_MAX ? kiln_db_thread_room(used + 1) : NULL;
    if (!buf) {
        lens[0] = -2;
        return empty;
    }
    buf[used] = 0;
    sp_ffi_bin_len = (int)used;
    return buf;
}

static size_t pg_cell(pg_sess *sess, const kiln_db_conn *conn, int row, int col, int bytea,
    size_t used, int64_t *len_out, int *ok) {
    const char *value;
    size_t len;
    char *buf;
    unsigned char *decoded = NULL;
    *ok = 1;
    if (pg.PQgetisnull(sess->held, row, col)) {
        *len_out = -1;
        return used;
    }
    value = pg.PQgetvalue(sess->held, row, col);
    len = (size_t)pg.PQgetlength(sess->held, row, col);
    if (bytea && conn->result_format == 0) {
        decoded = pg.PQunescapeBytea((const unsigned char *)value, &len);
        value = (const char *)decoded;
    }
    buf = value && len <= INT_MAX && used <= (size_t)INT_MAX - len ? kiln_db_thread_room(used + len + 1)
                                                                    : NULL;
    if (!buf) {
        *ok = 0;
    } else if (len) {
        memcpy(buf + used, value, len);
    }
    if (decoded) {
        pg.PQfreemem(decoded);
    }
    *len_out = (int64_t)len;
    return used + len;
}

const char *kiln_db_pg_result_rows(kiln_db_conn *conn, uint32_t first, uint32_t max_rows,
    size_t max_bytes, int64_t *lens, int lens_cap, int64_t *meta) {
    static __thread char empty[1];
    pg_sess *sess = conn->native;
    unsigned char bytea[KILN_DB_MAX_COLS];
    size_t used = 0;
    uint32_t taken = 0;
    int ntuples;
    int cols;
    int c;
    empty[0] = 0;
    if (!sess || !sess->held) {
        meta[0] = 0;
        return empty;
    }
    ntuples = pg.PQntuples(sess->held);
    cols = pg.PQnfields(sess->held);
    if (cols <= 0 || cols >= lens_cap || cols > KILN_DB_MAX_COLS) {
        return empty;
    }
    for (c = 0; c < cols; c++) {
        bytea[c] = pg.PQftype(sess->held, c) == 17;
    }
    while ((int64_t)first + taken < ntuples && taken < max_rows &&
           (int64_t)(taken + 1) * (cols + 1) <= lens_cap) {
        int row = (int)(first + taken);
        size_t start = used;
        size_t base = (size_t)taken * (size_t)(cols + 1);
        int ok = 1;
        for (c = 0; c < cols && ok; c++) {
            used = pg_cell(sess, conn, row, c, bytea[c], used, &lens[base + (size_t)c], &ok);
        }
        if (!ok) {
            return empty;
        }
        if (taken > 0 && used > max_bytes) {
            used = start;
            break;
        }
        lens[base + (size_t)cols] = (int64_t)(used - start);
        taken++;
    }
    meta[0] = taken;
    meta[1] = (int64_t)used;
    meta[2] = cols;
    sp_ffi_bin_len = (int)used;
    if (used == 0) {
        return empty;
    }
    return kiln_db_thread_room(used + 1);
}
