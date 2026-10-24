#include "kiln_db.h"

#include <dlfcn.h>
#include <fcntl.h>
#include <limits.h>
#include <mysql.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if !defined(MARIADB_PACKAGE_VERSION_ID) || MARIADB_PACKAGE_VERSION_ID < 30400
#error "Kiln::DB needs MariaDB Connector/C >= 3.4 headers: set KILN_DB_LIBMARIADB_PREFIX"
#endif

#define MY_RUNTIME_FLOOR 30400
#define MY_CELL_START    256
#define MY_STORE_TEXT    0
#define MY_STORE_I64     1
#define MY_STORE_F64     2
static void my_arm_socket(MYSQL *mysql);

#define MY_IDLE     0
#define MY_CONNECT  1
#define MY_QUERY    2
#define MY_PREPARE  3
#define MY_EXEC     4
#define MY_FETCH    5
#define MY_COMMIT     6
#define MY_ROLLBACK   7
#define MY_CLOSE_STMT 8

typedef struct {
    MYSQL *(*mysql_init)(MYSQL *mysql);
    int (*mysql_options)(MYSQL *mysql, enum mysql_option option, const void *arg);
    int (*mysql_ssl_set)(MYSQL *mysql, const char *key, const char *cert, const char *ca,
        const char *capath, const char *cipher);
    int (*mysql_real_connect_start)(MYSQL **ret, MYSQL *mysql, const char *host, const char *user,
        const char *passwd, const char *db, unsigned int port, const char *unix_socket,
        unsigned long clientflag);
    int (*mysql_real_connect_cont)(MYSQL **ret, MYSQL *mysql, int status);
    my_socket (*mysql_get_socket)(MYSQL *mysql);
    unsigned int (*mysql_get_timeout_value_ms)(const MYSQL *mysql);
    const char *(*mysql_get_ssl_cipher)(MYSQL *mysql);
    unsigned long (*mysql_get_client_version)(void);
    unsigned long (*mysql_thread_id)(MYSQL *mysql);
    unsigned int (*mysql_errno)(MYSQL *mysql);
    const char *(*mysql_error)(MYSQL *mysql);
    const char *(*mysql_sqlstate)(MYSQL *mysql);
    void (*mysql_close)(MYSQL *sock);
    MYSQL_STMT *(*mysql_stmt_init)(MYSQL *mysql);
    int (*mysql_stmt_prepare_start)(
        int *ret, MYSQL_STMT *stmt, const char *query, unsigned long length);
    int (*mysql_stmt_prepare_cont)(int *ret, MYSQL_STMT *stmt, int status);
    my_bool (*mysql_stmt_bind_param)(MYSQL_STMT *stmt, MYSQL_BIND *bnd);
    int (*mysql_stmt_execute_start)(int *ret, MYSQL_STMT *stmt);
    int (*mysql_stmt_execute_cont)(int *ret, MYSQL_STMT *stmt, int status);
    MYSQL_RES *(*mysql_stmt_result_metadata)(MYSQL_STMT *stmt);
    my_bool (*mysql_stmt_bind_result)(MYSQL_STMT *stmt, MYSQL_BIND *bnd);
    int (*mysql_stmt_fetch_start)(int *ret, MYSQL_STMT *stmt);
    int (*mysql_stmt_fetch_cont)(int *ret, MYSQL_STMT *stmt, int status);
    my_bool (*mysql_stmt_close)(MYSQL_STMT *stmt);
    int (*mysql_stmt_close_start)(my_bool *ret, MYSQL_STMT *stmt);
    int (*mysql_stmt_close_cont)(my_bool *ret, MYSQL_STMT *stmt, int status);
    unsigned int (*mysql_stmt_errno)(MYSQL_STMT *stmt);
    const char *(*mysql_stmt_sqlstate)(MYSQL_STMT *stmt);
    const char *(*mysql_stmt_error)(MYSQL_STMT *stmt);
    void (*mysql_free_result)(MYSQL_RES *result);
    int (*mysql_commit_start)(my_bool *ret, MYSQL *mysql);
    int (*mysql_commit_cont)(my_bool *ret, MYSQL *mysql, int status);
    int (*mysql_rollback_start)(my_bool *ret, MYSQL *mysql);
    int (*mysql_rollback_cont)(my_bool *ret, MYSQL *mysql, int status);
    int (*mysql_real_query_start)(int *ret, MYSQL *mysql, const char *q, unsigned long length);
    int (*mysql_real_query_cont)(int *ret, MYSQL *mysql, int status);
    my_bool (*mariadb_get_infov)(MYSQL *mysql, enum mariadb_value value, void *arg, ...);
    MYSQL_FIELD *(*mysql_fetch_fields)(MYSQL_RES *res);
    unsigned int (*mysql_num_fields)(MYSQL_RES *res);
    unsigned int (*mysql_field_count)(MYSQL *mysql);
    unsigned long long (*mysql_stmt_affected_rows)(MYSQL_STMT *stmt);
    unsigned int (*mysql_stmt_warning_count)(MYSQL_STMT *stmt);
    unsigned int (*mysql_warning_count)(MYSQL *mysql);
    unsigned long (*mysql_stmt_param_count)(MYSQL_STMT *stmt);
    int (*mysql_stmt_fetch_column)(
        MYSQL_STMT *stmt, MYSQL_BIND *bind_arg, unsigned int column, unsigned long offset);
} my_api;

typedef struct {
    uint64_t hash;
    char *sql;
    size_t len;
    MYSQL_STMT *stmt;
    uint64_t stamp;
    int unread;
} my_stmt_ent;

typedef struct {
    MYSQL *mysql;
    MYSQL_STMT *stmt;
    int phase;
    int status;
    int iret;
    int ncols;
    int bind_phase;
    int nparams;
    int pcap;
    my_bool bret;
    char verify;
    unsigned int protocol;
    MYSQL *connect_ret;
    const char *query;
    unsigned long query_len;
    unsigned long *param_len;
    char *param_null;
    char *param_error;
    char **param_buf;
    int *param_format;
    MYSQL_BIND *params;
    MYSQL_BIND *rbinds;
    unsigned long *rlen;
    unsigned long *rcap;
    char *rnull;
    char *rerr;
    char **rbuf;
    int *rtype;
    int *rstore;
    char *runsigned;
    int has_store;
    char *big;
    size_t big_cap;
    char *batch;
    size_t batch_len;
    size_t batch_cap;
    int64_t *cell_len;
    size_t *row_start;
    uint32_t rows;
    uint32_t rows_cap;
    uint32_t batch_max;
    int deferred_row;
    int warnings;
    int cap;
    int cache_set;
    int used;
    int close_n;
    int close_prepare;
    int reprepare;
    int prepare_exec;
    uint64_t clock;
    MYSQL_STMT *closing;
    MYSQL_STMT *hit_stmt;
    MYSQL_STMT *close_q[4];
    MYSQL_STMT **grave;
    int ngrave;
    int grave_cap;
    my_stmt_ent *slots;
} my_sess;

static my_api my;
static void *my_lib;
static pthread_mutex_t my_mu = PTHREAD_MUTEX_INITIALIZER;
static int my_loaded;
static int my_load_rc = KILN_DB_CONN;
static long my_version;

static const char *const my_names[] = {"libmariadb.3.dylib", "libmariadb.dylib",
    "/opt/homebrew/opt/mariadb-connector-c/lib/libmariadb.3.dylib",
    "/opt/homebrew/opt/mariadb-connector-c/lib/libmariadb.dylib", "libmariadb.so.3",
    "libmariadb.so", NULL};

static const char my_begin_sql[] = "START TRANSACTION";

static int my_step(kiln_db_conn *conn, int ready_bits, int64_t deadline_ms);
static void my_release(kiln_db_conn *conn);
static void my_cache_invalidate(my_sess *sess);
static int my_cache_store(my_sess *sess, kiln_db_conn *conn);
static void my_cache_forget_stmt(my_sess *sess, MYSQL_STMT *stmt);
static int my_prepare_handle(my_sess *sess, kiln_db_conn *conn, int make_new);
static int my_drain_closes(my_sess *sess, kiln_db_conn *conn);
static int my_queue_close(my_sess *sess, MYSQL_STMT *stmt);
static int my_begin_exec(my_sess *sess, kiln_db_conn *conn);

static int my_need(void **slot, const char *name) {
    void *sym = dlsym(my_lib, name);
    if (!sym) {
        kiln_db_set_load_error(name);
        return -1;
    }
    memcpy(slot, &sym, sizeof sym);
    return 0;
}

static int my_bind(void) {
    if (my_need((void **)&my.mysql_init, "mysql_init") ||
        my_need((void **)&my.mysql_options, "mysql_options") ||
        my_need((void **)&my.mysql_ssl_set, "mysql_ssl_set") ||
        my_need((void **)&my.mysql_real_connect_start, "mysql_real_connect_start") ||
        my_need((void **)&my.mysql_real_connect_cont, "mysql_real_connect_cont") ||
        my_need((void **)&my.mysql_get_socket, "mysql_get_socket") ||
        my_need((void **)&my.mysql_get_timeout_value_ms, "mysql_get_timeout_value_ms") ||
        my_need((void **)&my.mysql_get_ssl_cipher, "mysql_get_ssl_cipher") ||
        my_need((void **)&my.mysql_get_client_version, "mysql_get_client_version") ||
        my_need((void **)&my.mysql_thread_id, "mysql_thread_id") ||
        my_need((void **)&my.mysql_errno, "mysql_errno") ||
        my_need((void **)&my.mysql_error, "mysql_error") ||
        my_need((void **)&my.mysql_sqlstate, "mysql_sqlstate") ||
        my_need((void **)&my.mysql_close, "mysql_close") ||
        my_need((void **)&my.mysql_stmt_init, "mysql_stmt_init") ||
        my_need((void **)&my.mysql_stmt_prepare_start, "mysql_stmt_prepare_start") ||
        my_need((void **)&my.mysql_stmt_prepare_cont, "mysql_stmt_prepare_cont") ||
        my_need((void **)&my.mysql_stmt_bind_param, "mysql_stmt_bind_param") ||
        my_need((void **)&my.mysql_stmt_execute_start, "mysql_stmt_execute_start") ||
        my_need((void **)&my.mysql_stmt_execute_cont, "mysql_stmt_execute_cont") ||
        my_need((void **)&my.mysql_stmt_result_metadata, "mysql_stmt_result_metadata") ||
        my_need((void **)&my.mysql_stmt_bind_result, "mysql_stmt_bind_result") ||
        my_need((void **)&my.mysql_stmt_fetch_start, "mysql_stmt_fetch_start") ||
        my_need((void **)&my.mysql_stmt_fetch_cont, "mysql_stmt_fetch_cont") ||
        my_need((void **)&my.mysql_stmt_close, "mysql_stmt_close") ||
        my_need((void **)&my.mysql_stmt_close_start, "mysql_stmt_close_start") ||
        my_need((void **)&my.mysql_stmt_close_cont, "mysql_stmt_close_cont") ||
        my_need((void **)&my.mysql_stmt_errno, "mysql_stmt_errno") ||
        my_need((void **)&my.mysql_stmt_sqlstate, "mysql_stmt_sqlstate") ||
        my_need((void **)&my.mysql_stmt_error, "mysql_stmt_error") ||
        my_need((void **)&my.mysql_free_result, "mysql_free_result") ||
        my_need((void **)&my.mysql_commit_start, "mysql_commit_start") ||
        my_need((void **)&my.mysql_commit_cont, "mysql_commit_cont") ||
        my_need((void **)&my.mysql_rollback_start, "mysql_rollback_start") ||
        my_need((void **)&my.mysql_rollback_cont, "mysql_rollback_cont") ||
        my_need((void **)&my.mysql_real_query_start, "mysql_real_query_start") ||
        my_need((void **)&my.mysql_real_query_cont, "mysql_real_query_cont") ||
        my_need((void **)&my.mariadb_get_infov, "mariadb_get_infov") ||
        my_need((void **)&my.mysql_fetch_fields, "mysql_fetch_fields") ||
        my_need((void **)&my.mysql_num_fields, "mysql_num_fields") ||
        my_need((void **)&my.mysql_field_count, "mysql_field_count") ||
        my_need((void **)&my.mysql_stmt_affected_rows, "mysql_stmt_affected_rows") ||
        my_need((void **)&my.mysql_stmt_warning_count, "mysql_stmt_warning_count") ||
        my_need((void **)&my.mysql_warning_count, "mysql_warning_count") ||
        my_need((void **)&my.mysql_stmt_param_count, "mysql_stmt_param_count") ||
        my_need((void **)&my.mysql_stmt_fetch_column, "mysql_stmt_fetch_column")) {
        return -1;
    }
    return 0;
}

static void *my_open(void) {
    const char *env = getenv("KILN_LIBMARIADB");
    int i;
    if (env && env[0]) {
        return dlopen(env, RTLD_NOW | RTLD_LOCAL);
    }
    for (i = 0; my_names[i]; i++) {
        void *handle = dlopen(my_names[i], RTLD_NOW | RTLD_LOCAL);
        if (handle) {
            return handle;
        }
    }
    return NULL;
}

static int my_load_now(void) {
    my_lib = my_open();
    if (!my_lib) {
        kiln_db_set_load_error("libmariadb");
        return KILN_DB_CONN;
    }
    if (my_bind() != 0) {
        dlclose(my_lib);
        my_lib = NULL;
        return KILN_DB_CONN;
    }
    my_version = (long)my.mysql_get_client_version();
    if (my_version < MY_RUNTIME_FLOOR) {
        kiln_db_set_load_error("mysql_get_client_version");
        dlclose(my_lib);
        my_lib = NULL;
        my_version = 0;
        return KILN_DB_CONN;
    }
    kiln_db_driver_register(KILN_DB_KIND_MY, my_step, my_release);
    kiln_db_set_load_error(NULL);
    return KILN_DB_OK;
}

int kiln_db_my_load(void) {
    int rc;
    pthread_mutex_lock(&my_mu);
    if (my_loaded) {
        rc = my_load_rc;
        pthread_mutex_unlock(&my_mu);
        return rc;
    }
    rc = my_load_now();
    my_load_rc = rc;
    if (rc == KILN_DB_OK) {
        my_loaded = 1;
    }
    pthread_mutex_unlock(&my_mu);
    return rc;
}

long kiln_db_my_client_version(void) {
    if (kiln_db_my_load() != KILN_DB_OK) {
        return 0;
    }
    return my_version;
}

static my_sess *my_session(kiln_db_conn *conn) {
    if (!conn->native) {
        my_sess *sess = calloc(1, sizeof *sess);
        if (!sess) {
            return NULL;
        }
        conn->native = sess;
        conn->fd = -1;
    }
    return conn->native;
}

static int my_fail(my_sess *sess, kiln_db_conn *conn, int code, int vendor, const char *state,
    const char *message) {
    if (sess && conn && conn->broken) {
        my_cache_invalidate(sess);
    }
    if (sess) {
        sess->phase = MY_IDLE;
    }
    kiln_db_fail(conn, code, vendor, state, message ? message : "");
    return KILN_DB_STEP_ERR;
}

static int my_vendor_code(unsigned int vendor) {
    switch (vendor) {
    case 1062u:
    case 1586u:
        return KILN_DB_UNIQUE;
    case 1216u:
    case 1217u:
    case 1451u:
    case 1452u:
        return KILN_DB_FK;
    case 1048u:
    case 1364u:
        return KILN_DB_NOTNULL;
    case 3819u:
    case 4025u:
        return KILN_DB_CHECK;
    case 1213u:
        return KILN_DB_DEADLOCK;
    case 1205u:
        return KILN_DB_LOCKWAIT;
    case 1295u:
        return KILN_DB_UNSUPPORTED;
    default:
        break;
    }
    if (vendor >= 2000u && vendor < 3000u) {
        return KILN_DB_CONN;
    }
    return KILN_DB_ERR;
}

static int my_stmt_unknown(unsigned int vendor, const char *state);

static int my_conn_fail(my_sess *sess, kiln_db_conn *conn) {
    const char *state = my.mysql_sqlstate(sess->mysql);
    const char *message = my.mysql_error(sess->mysql);
    unsigned int vendor = my.mysql_errno(sess->mysql);
    int code = my_vendor_code(vendor);
    if (code == KILN_DB_CONN || my_stmt_unknown(vendor, state)) {
        conn->broken = 1;
    }
    return my_fail(
        sess, conn, code, vendor > 2147483647u ? 2147483647 : (int)vendor, state, message);
}

static void my_note_warnings(my_sess *sess) {
    unsigned int n = 0;
    unsigned int conn_n = 0;
    if (sess->stmt) {
        n = my.mysql_stmt_warning_count(sess->stmt);
    }
    if (sess->mysql) {
        conn_n = my.mysql_warning_count(sess->mysql);
    }
    if (conn_n > n) {
        n = conn_n;
    }
    sess->warnings = n > 2147483647u ? 2147483647 : (int)n;
}

static int my_stmt_unknown(unsigned int vendor, const char *state) {
    if (vendor == 1243u) {
        return 1;
    }
    return state && state[0] == '0' && state[1] == '8';
}

static int my_stmt_fail(my_sess *sess, kiln_db_conn *conn) {
    const char *state = sess->stmt ? my.mysql_stmt_sqlstate(sess->stmt) : NULL;
    const char *message = sess->stmt ? my.mysql_stmt_error(sess->stmt) : "statement";
    unsigned int vendor = sess->stmt ? my.mysql_stmt_errno(sess->stmt) : 0;
    int vendor_i = vendor > 2147483647u ? 2147483647 : (int)vendor;
    int code = my_vendor_code(vendor);
    if (code == KILN_DB_CONN || my_stmt_unknown(vendor, state)) {
        conn->broken = 1;
    }
    return my_fail(sess, conn, code, vendor_i, state, message);
}

static int my_park(my_sess *sess, kiln_db_conn *conn, int status) {
    int kind = 0;
    int fd;
    sess->status = status;
    if (status & MYSQL_WAIT_READ) {
        kind |= KILN_DB_READY_READ;
    }
    if (status & MYSQL_WAIT_WRITE) {
        kind |= KILN_DB_READY_WRITE;
    }
    if ((status & MYSQL_WAIT_EXCEPT) && (kind & KILN_DB_READY_READ) == 0) {
        kind |= KILN_DB_READY_READ;
    }
    fd = sess->mysql ? (int)my.mysql_get_socket(sess->mysql) : -1;
    if (kind == 0 || fd < 0) {
        unsigned int ms = 10;
        if (sess->mysql && (status & MYSQL_WAIT_TIMEOUT)) {
            ms = my.mysql_get_timeout_value_ms(sess->mysql);
            if (ms == 0) {
                ms = 10;
            }
        }
        conn->fd = -1;
        conn->wait_kind = KILN_DB_READY_TIMEOUT;
        conn->wait_ms = ms;
        return KILN_DB_STEP_WAIT;
    }
    conn->fd = fd;
    conn->wait_kind = kind;
    conn->wait_ms = 0;
    return KILN_DB_STEP_WAIT;
}

static int my_mask(const my_sess *sess, int ready_bits) {
    int mask = 0;
    if (ready_bits & KILN_DB_READY_READ) {
        mask |= MYSQL_WAIT_READ;
    }
    if (ready_bits & KILN_DB_READY_WRITE) {
        mask |= MYSQL_WAIT_WRITE;
    }
    if (ready_bits & KILN_DB_READY_TIMEOUT) {
        mask |= MYSQL_WAIT_TIMEOUT;
    }
    if ((sess->status & MYSQL_WAIT_EXCEPT) && (ready_bits & KILN_DB_READY_READ)) {
        mask |= MYSQL_WAIT_EXCEPT;
    }
    return mask;
}

static void my_free_results(my_sess *sess) {
    int i;
    for (i = 0; i < sess->ncols; i++) {
        free(sess->rbuf[i]);
    }
    free(sess->rbinds);
    free(sess->rlen);
    free(sess->rcap);
    free(sess->rnull);
    free(sess->rerr);
    free(sess->rbuf);
    free(sess->rtype);
    free(sess->rstore);
    free(sess->runsigned);
    sess->rbinds = NULL;
    sess->rlen = NULL;
    sess->rcap = NULL;
    sess->rnull = NULL;
    sess->rerr = NULL;
    sess->rbuf = NULL;
    sess->rtype = NULL;
    sess->rstore = NULL;
    sess->runsigned = NULL;
    sess->has_store = 0;
    sess->ncols = 0;
    sess->rows = 0;
    sess->rows_cap = 0;
    sess->batch_len = 0;
    sess->deferred_row = 0;
}

static void my_clear_params(my_sess *sess) {
    int i;
    for (i = 0; i < sess->nparams; i++) {
        free(sess->param_buf[i]);
        sess->param_buf[i] = NULL;
    }
    sess->nparams = 0;
}

static void my_drop_params(my_sess *sess) {
    my_clear_params(sess);
    free(sess->param_len);
    free(sess->param_null);
    free(sess->param_error);
    free(sess->param_buf);
    free(sess->param_format);
    free(sess->params);
    sess->param_len = NULL;
    sess->param_null = NULL;
    sess->param_error = NULL;
    sess->param_buf = NULL;
    sess->param_format = NULL;
    sess->params = NULL;
    sess->pcap = 0;
}

static void *my_grow(void *ptr, size_t old_n, size_t new_n, size_t size) {
    char *next = realloc(ptr, new_n * size);
    if (!next) {
        return NULL;
    }
    memset(next + old_n * size, 0, (new_n - old_n) * size);
    return next;
}

static int my_reserve_params(my_sess *sess, int want) {
    int cap = sess->pcap ? sess->pcap : 16;
    void *next;
    if (want <= sess->pcap) {
        return KILN_DB_OK;
    }
    while (cap < want) {
        cap *= 2;
    }
    if (cap > KILN_DB_MAX_PARAMS) {
        cap = KILN_DB_MAX_PARAMS;
    }
    next = my_grow(sess->param_len, (size_t)sess->pcap, (size_t)cap, sizeof *sess->param_len);
    if (!next) {
        return KILN_DB_CAPACITY;
    }
    sess->param_len = next;
    next = my_grow(sess->param_null, (size_t)sess->pcap, (size_t)cap, 1);
    if (!next) {
        return KILN_DB_CAPACITY;
    }
    sess->param_null = next;
    next = my_grow(sess->param_error, (size_t)sess->pcap, (size_t)cap, 1);
    if (!next) {
        return KILN_DB_CAPACITY;
    }
    sess->param_error = next;
    next = my_grow(sess->param_buf, (size_t)sess->pcap, (size_t)cap, sizeof *sess->param_buf);
    if (!next) {
        return KILN_DB_CAPACITY;
    }
    sess->param_buf = next;
    next = my_grow(sess->param_format, (size_t)sess->pcap, (size_t)cap, sizeof *sess->param_format);
    if (!next) {
        return KILN_DB_CAPACITY;
    }
    sess->param_format = next;
    next = my_grow(sess->params, (size_t)sess->pcap, (size_t)cap, sizeof *sess->params);
    if (!next) {
        return KILN_DB_CAPACITY;
    }
    sess->params = next;
    sess->pcap = cap;
    return KILN_DB_OK;
}

static int my_bind_params(my_sess *sess) {
    int i;
    int count = sess->nparams;
    unsigned long want = my.mysql_stmt_param_count(sess->stmt);
    if ((unsigned long)count != want) {
        return KILN_DB_CONFIG;
    }
    if (count <= 0) {
        return KILN_DB_OK;
    }
    for (i = 0; i < count; i++) {
        int type = sess->param_format[i] ? MYSQL_TYPE_BLOB : MYSQL_TYPE_STRING;
        if (!sess->param_buf[i]) {
            sess->param_null[i] = 1;
        }
        if (kiln_db_my_bind_set(&sess->params[i], sess->param_buf[i], sess->param_len[i],
                &sess->param_len[i], &sess->param_null[i], &sess->param_error[i],
                type) != KILN_DB_OK) {
            return KILN_DB_ERR;
        }
    }
    if (my.mysql_stmt_bind_param(sess->stmt, sess->params) != 0) {
        return KILN_DB_ERR;
    }
    return KILN_DB_OK;
}

static int my_field_type(const MYSQL_FIELD *f) {
    switch (f->type) {
    case MYSQL_TYPE_TINY:
    case MYSQL_TYPE_SHORT:
    case MYSQL_TYPE_LONG:
    case MYSQL_TYPE_INT24:
    case MYSQL_TYPE_YEAR:
        return KILN_DB_T_INT;
    case MYSQL_TYPE_LONGLONG:
        return (f->flags & UNSIGNED_FLAG) ? KILN_DB_T_UINT : KILN_DB_T_INT;
    case MYSQL_TYPE_FLOAT:
    case MYSQL_TYPE_DOUBLE:
        return KILN_DB_T_FLOAT;
    case MYSQL_TYPE_DECIMAL:
    case MYSQL_TYPE_NEWDECIMAL:
        return KILN_DB_T_DECIMAL;
    case MYSQL_TYPE_BIT:
        return KILN_DB_T_BINARY;
    case MYSQL_TYPE_JSON:
        return KILN_DB_T_TEXT;
    case MYSQL_TYPE_TINY_BLOB:
    case MYSQL_TYPE_MEDIUM_BLOB:
    case MYSQL_TYPE_LONG_BLOB:
    case MYSQL_TYPE_BLOB:
    case MYSQL_TYPE_STRING:
    case MYSQL_TYPE_VAR_STRING:
    case MYSQL_TYPE_VARCHAR:
        return f->charsetnr == 63 ? KILN_DB_T_BINARY : KILN_DB_T_TEXT;
    default:
        return KILN_DB_T_TEXT;
    }
}

static int my_alloc_cols(my_sess *sess, unsigned int n) {
    sess->rbinds = calloc(n, sizeof *sess->rbinds);
    sess->rlen = calloc(n, sizeof *sess->rlen);
    sess->rcap = calloc(n, sizeof *sess->rcap);
    sess->rnull = calloc(n, 1);
    sess->rerr = calloc(n, 1);
    sess->rbuf = calloc(n, sizeof *sess->rbuf);
    sess->rtype = calloc(n, sizeof *sess->rtype);
    sess->rstore = calloc(n, sizeof *sess->rstore);
    sess->runsigned = calloc(n, sizeof *sess->runsigned);
    return sess->rbinds && sess->rlen && sess->rcap && sess->rnull && sess->rerr && sess->rbuf &&
           sess->rtype && sess->rstore && sess->runsigned;
}

static int my_field_store(const MYSQL_FIELD *f) {
    switch (f->type) {
    case MYSQL_TYPE_TINY:
    case MYSQL_TYPE_SHORT:
    case MYSQL_TYPE_INT24:
    case MYSQL_TYPE_LONG:
        return MY_STORE_I64;
    case MYSQL_TYPE_LONGLONG:
        return (f->flags & UNSIGNED_FLAG) ? MY_STORE_TEXT : MY_STORE_I64;
    case MYSQL_TYPE_DOUBLE:
        return MY_STORE_F64;
    default:
        return MY_STORE_TEXT;
    }
}

static int my_take_meta(my_sess *sess, kiln_db_conn *conn) {
    MYSQL_RES *meta = my.mysql_stmt_result_metadata(sess->stmt);
    MYSQL_FIELD *fields;
    unsigned int n;
    unsigned int i;
    unsigned long long affected;
    my_note_warnings(sess);
    my_free_results(sess);
    if (!meta) {
        affected = my.mysql_stmt_affected_rows(sess->stmt);
        if (affected > 2147483647ull) {
            conn->rows_affected = 2147483647;
        } else {
            conn->rows_affected = (int)affected;
        }
        conn->fetch_done = 1;
        sess->phase = MY_IDLE;
        conn->fd = (int)my.mysql_get_socket(sess->mysql);
        conn->wait_kind = 0;
        return KILN_DB_STEP_DONE;
    }
    n = my.mysql_num_fields(meta);
    fields = my.mysql_fetch_fields(meta);
    if (n == 0 || n > KILN_DB_MAX_COLS || !fields) {
        my.mysql_free_result(meta);
        return my_fail(sess, conn, n > KILN_DB_MAX_COLS ? KILN_DB_CAPACITY : KILN_DB_ERR, 0, NULL,
            "result columns");
    }
    if (!my_alloc_cols(sess, n)) {
        my.mysql_free_result(meta);
        my_free_results(sess);
        return my_fail(sess, conn, KILN_DB_CAPACITY, 0, NULL, "result columns");
    }
    sess->ncols = (int)n;
    for (i = 0; i < n; i++) {
        unsigned long len = fields[i].length;
        if (len == 0) {
            len = 1;
        }
        if (len > MY_CELL_START) {
            len = MY_CELL_START;
        }
        sess->rtype[i] = my_field_type(&fields[i]);
        sess->rstore[i] = my_field_store(&fields[i]);
        sess->runsigned[i] = (fields[i].flags & UNSIGNED_FLAG) ? 1 : 0;
        if (sess->rstore[i] != MY_STORE_TEXT) {
            len = 8;
            sess->has_store = 1;
        }
        sess->rbuf[i] = malloc(len);
        if (!sess->rbuf[i]) {
            my.mysql_free_result(meta);
            my_free_results(sess);
            return my_fail(sess, conn, KILN_DB_CAPACITY, 0, NULL, "field buffer");
        }
        sess->rcap[i] = len;
        {
            int btype = MYSQL_TYPE_STRING;
            if (sess->rstore[i] == MY_STORE_I64) {
                btype = MYSQL_TYPE_LONGLONG;
            } else if (sess->rstore[i] == MY_STORE_F64) {
                btype = MYSQL_TYPE_DOUBLE;
            } else if (sess->rtype[i] == KILN_DB_T_BINARY) {
                btype = MYSQL_TYPE_BLOB;
            }
            kiln_db_my_bind_set(&sess->rbinds[i], sess->rbuf[i], len, &sess->rlen[i],
                &sess->rnull[i], &sess->rerr[i], btype);
            if (sess->rstore[i] == MY_STORE_I64) {
                sess->rbinds[i].is_unsigned = sess->runsigned[i] ? 1 : 0;
            }
        }
    }
    my.mysql_free_result(meta);
    if (my.mysql_stmt_bind_result(sess->stmt, sess->rbinds) != 0) {
        return my_stmt_fail(sess, conn);
    }
    return 1;
}

static int my_room(char **buf, size_t *cap, size_t want) {
    size_t next_cap = *cap ? *cap : 4096;
    char *next;
    if (want <= *cap) {
        return 1;
    }
    while (next_cap < want) {
        next_cap *= 2;
    }
    next = realloc(*buf, next_cap);
    if (!next) {
        return 0;
    }
    *buf = next;
    *cap = next_cap;
    return 1;
}

static int my_row_slots(my_sess *sess) {
    uint32_t need = sess->rows + 1;
    uint32_t cap = sess->rows_cap ? sess->rows_cap : 64;
    void *next;
    if (need <= sess->rows_cap) {
        return 1;
    }
    while (cap < need) {
        cap *= 2;
    }
    next = realloc(sess->cell_len, (size_t)cap * (size_t)sess->ncols * sizeof *sess->cell_len);
    if (!next) {
        return 0;
    }
    sess->cell_len = next;
    next = realloc(sess->row_start, ((size_t)cap + 1) * sizeof *sess->row_start);
    if (!next) {
        return 0;
    }
    sess->row_start = next;
    sess->rows_cap = cap;
    return 1;
}

static int my_batch_room(my_sess *sess, size_t need, size_t limit) {
    size_t cap = sess->batch_cap ? sess->batch_cap : 256;
    char *next;
    if (need > limit) {
        return 0;
    }
    if (need <= sess->batch_cap) {
        return 1;
    }
    if (cap > limit) {
        cap = limit;
    }
    while (cap < need) {
        if (cap > limit / 2) {
            cap = limit;
            break;
        }
        cap *= 2;
    }
    next = realloc(sess->batch, cap);
    if (!next) {
        return 0;
    }
    sess->batch = next;
    sess->batch_cap = cap;
    return 1;
}

static int my_take_row(my_sess *sess) {
    const kiln_db_limits *limits = kiln_db_limits_get();
    size_t max_cell = limits ? limits->max_payload_bytes : 67108864u;
    size_t row_bytes = 0;
    int i;
    for (i = 0; i < sess->ncols; i++) {
        size_t len;
        if (sess->rnull[i]) {
            continue;
        }
        if (sess->rstore[i] != MY_STORE_TEXT) {
            if (sess->rerr[i]) {
                return KILN_DB_ERR;
            }
            len = 8;
        } else {
            len = sess->rlen[i];
        }
        if (len > max_cell || len > max_cell - row_bytes) {
            return KILN_DB_CAPACITY;
        }
        row_bytes += len;
    }
    if (row_bytes >= max_cell - sess->batch_len) {
        return sess->rows > 0 ? KILN_DB_BUSY : KILN_DB_CAPACITY;
    }
    if (!my_row_slots(sess)) {
        return KILN_DB_CAPACITY;
    }
    sess->row_start[sess->rows] = sess->batch_len;
    for (i = 0; i < sess->ncols; i++) {
        size_t at = ((size_t)sess->rows * (size_t)sess->ncols) + (size_t)i;
        const char *src = sess->rbuf[i];
        size_t len;
        if (sess->rnull[i]) {
            sess->cell_len[at] = -1;
            continue;
        }
        if (sess->rstore[i] != MY_STORE_TEXT) {
            len = 8;
            src = sess->rbuf[i];
        } else {
            len = sess->rlen[i];
            if (len > max_cell) {
                return KILN_DB_CAPACITY;
            }
            if (len > sess->rcap[i]) {
                MYSQL_BIND whole;
                unsigned long got = 0;
                char is_null = 0;
                char err = 0;
                if (!my_room(&sess->big, &sess->big_cap, len)) {
                    return KILN_DB_CAPACITY;
                }
                kiln_db_my_bind_set(&whole, sess->big, (unsigned long)len, &got, &is_null, &err,
                    sess->rtype[i] == KILN_DB_T_BINARY ? MYSQL_TYPE_BLOB : MYSQL_TYPE_STRING);
                if (my.mysql_stmt_fetch_column(sess->stmt, &whole, (unsigned int)i, 0) != 0 ||
                    got != len) {
                    return KILN_DB_ERR;
                }
                src = sess->big;
            }
        }
        if (!my_batch_room(sess, sess->batch_len + len + 1, max_cell)) {
            return KILN_DB_CAPACITY;
        }
        if (len) {
            memcpy(sess->batch + sess->batch_len, src, len);
        }
        sess->batch_len += len;
        sess->cell_len[at] = (int64_t)len;
    }
    sess->rows++;
    sess->row_start[sess->rows] = sess->batch_len;
    return KILN_DB_OK;
}

static int my_fetch_loop(my_sess *sess, kiln_db_conn *conn, int resumed, int mask) {
    for (;;) {
        int taken;
        if (resumed) {
            sess->status = my.mysql_stmt_fetch_cont(&sess->iret, sess->stmt, mask);
            resumed = 0;
        } else {
            my_arm_socket(sess->mysql);
            sess->status = my.mysql_stmt_fetch_start(&sess->iret, sess->stmt);
        }
        if (sess->status) {
            return my_park(sess, conn, sess->status);
        }
        if (sess->iret == MYSQL_NO_DATA) {
            my_note_warnings(sess);
            conn->fetch_done = 1;
            sess->phase = MY_IDLE;
            conn->wait_kind = 0;
            conn->fd = (int)my.mysql_get_socket(sess->mysql);
            return KILN_DB_STEP_DONE;
        }
        if (sess->iret != 0 && sess->iret != MYSQL_DATA_TRUNCATED) {
            return my_stmt_fail(sess, conn);
        }
        taken = my_take_row(sess);
        if (taken == KILN_DB_BUSY) {
            sess->deferred_row = 1;
            conn->fetch_done = 0;
            sess->phase = MY_IDLE;
            conn->wait_kind = 0;
            conn->fd = (int)my.mysql_get_socket(sess->mysql);
            return KILN_DB_STEP_DONE;
        }
        if (taken != KILN_DB_OK) {
            conn->broken = 1;
            return my_fail(sess, conn, taken, 0, NULL, "row");
        }
        if (sess->rows >= sess->batch_max) {
            my_note_warnings(sess);
            conn->fetch_done = 0;
            sess->phase = MY_IDLE;
            conn->wait_kind = 0;
            conn->fd = (int)my.mysql_get_socket(sess->mysql);
            return KILN_DB_STEP_DONE;
        }
    }
}

static int my_begin_fetch(my_sess *sess, kiln_db_conn *conn) {
    const kiln_db_limits *limits = kiln_db_limits_get();
    sess->rows = 0;
    sess->batch_len = 0;
    sess->batch_max = limits && limits->block_rows ? limits->block_rows : 1024u;
    sess->phase = MY_FETCH;
    if (sess->deferred_row) {
        int rc = my_take_row(sess);
        if (rc != KILN_DB_OK) {
            conn->broken = 1;
            return my_fail(sess, conn, rc, 0, NULL, "deferred row");
        }
        sess->deferred_row = 0;
        if (sess->rows >= sess->batch_max) {
            conn->fetch_done = 0;
            sess->phase = MY_IDLE;
            conn->wait_kind = 0;
            return KILN_DB_STEP_DONE;
        }
    }
    return my_fetch_loop(sess, conn, 0, 0);
}

static int my_after_exec(my_sess *sess, kiln_db_conn *conn) {
    int meta;
    unsigned int vendor;
    if (sess->iret != 0) {
        vendor = sess->stmt ? my.mysql_stmt_errno(sess->stmt) : 0;
        if ((vendor == 1615u || vendor == 2057u) && !sess->reprepare) {
            sess->reprepare = 1;
            sess->prepare_exec = 1;
            my_cache_forget_stmt(sess, sess->stmt);
            if (vendor == 2057u) {
                if (!my_queue_close(sess, sess->stmt)) {
                    return my_fail(sess, conn, KILN_DB_CAPACITY, 0, NULL, "statement cache");
                }
                sess->stmt = NULL;
                sess->close_prepare = 1;
                sess->hit_stmt = NULL;
                return my_drain_closes(sess, conn);
            }
            return my_prepare_handle(sess, conn, 0);
        }
        sess->reprepare = 0;
        sess->prepare_exec = 0;
        return my_stmt_fail(sess, conn);
    }
    sess->reprepare = 0;
    meta = my_take_meta(sess, conn);
    if (meta != 1) {
        return meta;
    }
    return my_begin_fetch(sess, conn);
}

static int my_after_query(my_sess *sess, kiln_db_conn *conn) {
    if (sess->iret != 0) {
        return my_conn_fail(sess, conn);
    }
    if (my.mysql_field_count(sess->mysql) > 0) {
        conn->broken = 1;
        return my_fail(sess, conn, KILN_DB_UNSUPPORTED, 0, NULL, "simple command returned rows");
    }
    my_note_warnings(sess);
    conn->fetch_done = 1;
    conn->rows_affected = 0;
    sess->phase = MY_IDLE;
    conn->fd = (int)my.mysql_get_socket(sess->mysql);
    conn->wait_kind = 0;
    return KILN_DB_STEP_DONE;
}

static int my_after_prepare(my_sess *sess, kiln_db_conn *conn) {
    int again;
    if (sess->iret != 0) {
        sess->prepare_exec = 0;
        sess->reprepare = 0;
        conn->prepared = 0;
        return my_stmt_fail(sess, conn);
    }
    if (!my_cache_store(sess, conn)) {
        return my_fail(sess, conn, KILN_DB_CAPACITY, 0, NULL, "statement cache");
    }
    conn->prepared = 1;
    conn->fetch_done = 1;
    again = sess->prepare_exec;
    sess->prepare_exec = 0;
    if (again) {
        return my_begin_exec(sess, conn);
    }
    sess->phase = MY_IDLE;
    conn->fd = (int)my.mysql_get_socket(sess->mysql);
    conn->wait_kind = 0;
    return KILN_DB_STEP_DONE;
}

static int my_after_flag(my_sess *sess, kiln_db_conn *conn) {
    if (sess->bret != 0) {
        return my_conn_fail(sess, conn);
    }
    conn->fetch_done = 1;
    sess->phase = MY_IDLE;
    conn->fd = (int)my.mysql_get_socket(sess->mysql);
    conn->wait_kind = 0;
    return KILN_DB_STEP_DONE;
}

static int my_tls_ok(my_sess *sess, kiln_db_conn *conn) {
    const char *cipher;
    char *host = NULL;
    int kind = -1;
    unsigned int verify = 1;
    if (conn->ssl_mode != KILN_DB_SSL_VERIFY_FULL) {
        return KILN_DB_OK;
    }
    cipher = my.mysql_get_ssl_cipher(sess->mysql);
    if (!cipher || !cipher[0]) {
        return KILN_DB_CONN;
    }
    if (my.mariadb_get_infov(sess->mysql, MARIADB_CONNECTION_TYPE, &kind) != 0 || kind != 1) {
        return KILN_DB_CONN;
    }
    if (my.mariadb_get_infov(sess->mysql, MARIADB_CONNECTION_HOST, &host) != 0 || !host ||
        !conn->tls_name || strcmp(host, conn->tls_name) != 0) {
        return KILN_DB_CONN;
    }
    if (my.mariadb_get_infov(sess->mysql, MARIADB_TLS_VERIFY_STATUS, &verify) != 0 ||
        verify != MARIADB_TLS_VERIFY_OK) {
        return KILN_DB_CONN;
    }
    return KILN_DB_OK;
}

static int my_after_connect(my_sess *sess, kiln_db_conn *conn) {
    int fd;
    if (!sess->connect_ret) {
        return my_conn_fail(sess, conn);
    }
    if (my_tls_ok(sess, conn) != KILN_DB_OK) {
        return my_fail(sess, conn, KILN_DB_CONN, 0, NULL, "tls required");
    }
    fd = (int)my.mysql_get_socket(sess->mysql);
    if (fd < 0) {
        return my_fail(sess, conn, KILN_DB_CONN, 0, NULL, "socket");
    }
    conn->mysql_thread = my.mysql_thread_id(sess->mysql);
    conn->fd = fd;
    conn->wait_kind = 0;
    conn->fetch_done = 1;
    sess->phase = MY_IDLE;
    return KILN_DB_STEP_DONE;
}

static int my_resume(my_sess *sess, kiln_db_conn *conn, int ready_bits) {
    int mask = my_mask(sess, ready_bits);
    my_arm_socket(sess->mysql);
    if (sess->phase == MY_CONNECT) {
        sess->status = my.mysql_real_connect_cont(&sess->connect_ret, sess->mysql, mask);
        if (sess->status) {
            return my_park(sess, conn, sess->status);
        }
        return my_after_connect(sess, conn);
    }
    if (sess->phase == MY_QUERY) {
        sess->status = my.mysql_real_query_cont(&sess->iret, sess->mysql, mask);
        if (sess->status) {
            return my_park(sess, conn, sess->status);
        }
        return my_after_query(sess, conn);
    }
    if (sess->phase == MY_PREPARE) {
        sess->status = my.mysql_stmt_prepare_cont(&sess->iret, sess->stmt, mask);
        if (sess->status) {
            return my_park(sess, conn, sess->status);
        }
        return my_after_prepare(sess, conn);
    }
    if (sess->phase == MY_CLOSE_STMT) {
        sess->status = my.mysql_stmt_close_cont(&sess->bret, sess->closing, mask);
        if (sess->status) {
            return my_park(sess, conn, sess->status);
        }
        sess->closing = NULL;
        if (sess->bret != 0) {
            conn->broken = 1;
            my_cache_invalidate(sess);
            return my_conn_fail(sess, conn);
        }
        return my_drain_closes(sess, conn);
    }
    if (sess->phase == MY_EXEC) {
        sess->status = my.mysql_stmt_execute_cont(&sess->iret, sess->stmt, mask);
        if (sess->status) {
            return my_park(sess, conn, sess->status);
        }
        return my_after_exec(sess, conn);
    }
    if (sess->phase == MY_FETCH) {
        my_arm_socket(sess->mysql);
        return my_fetch_loop(sess, conn, 1, mask);
    }
    if (sess->phase == MY_COMMIT) {
        sess->status = my.mysql_commit_cont(&sess->bret, sess->mysql, mask);
        if (sess->status) {
            return my_park(sess, conn, sess->status);
        }
        return my_after_flag(sess, conn);
    }
    if (sess->phase == MY_ROLLBACK) {
        sess->status = my.mysql_rollback_cont(&sess->bret, sess->mysql, mask);
        if (sess->status) {
            return my_park(sess, conn, sess->status);
        }
        return my_after_flag(sess, conn);
    }
    return my_fail(sess, conn, KILN_DB_ERR, 0, NULL, "phase");
}

static int my_rejected_name(const char *name) {
    return name && (strcmp(name, "127.0.0.1") == 0 || strcmp(name, "::1") == 0);
}

static void my_arm_socket(MYSQL *mysql) {
    int fd;
    int flags;
    if (!mysql || !my.mysql_get_socket) {
        return;
    }
    fd = (int)my.mysql_get_socket(mysql);
    if (fd < 0) {
        return;
    }
    flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0 || (flags & O_NONBLOCK) != 0) {
        return;
    }
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static int my_plain(my_sess *sess) {
    sess->verify = 0;
    if (my.mysql_options(sess->mysql, MYSQL_OPT_SSL_ENFORCE, &sess->verify) != 0) {
        return 1;
    }
    return my.mysql_options(sess->mysql, MYSQL_OPT_SSL_VERIFY_SERVER_CERT, &sess->verify);
}

static int my_begin_connect(my_sess *sess, kiln_db_conn *conn) {
    const char *host;
    unsigned long flags = 0;
    if (sess->mysql) {
        return my_fail(sess, conn, KILN_DB_CONN, 0, NULL, "already connected");
    }
    if (conn->port <= 0) {
        return my_fail(sess, conn, KILN_DB_CONFIG, 0, NULL, "port");
    }
    if (conn->ssl_mode == KILN_DB_SSL_VERIFY_FULL) {
        host = conn->tls_name;
        if (my_rejected_name(host)) {
            return my_fail(sess, conn, KILN_DB_CONFIG, 0, NULL, "tls name");
        }
        if (!conn->ca_path || !conn->ca_path[0]) {
            return my_fail(sess, conn, KILN_DB_CONFIG, 0, NULL, "ca");
        }
        flags = CLIENT_SSL;
    } else {
        host = conn->host;
    }
    if (!host || !host[0]) {
        return my_fail(sess, conn, KILN_DB_CONFIG, 0, NULL, "missing host");
    }
    sess->mysql = my.mysql_init(NULL);
    if (!sess->mysql) {
        return my_fail(sess, conn, KILN_DB_CONN, 0, NULL, "mysql_init");
    }
    if (my.mysql_options(sess->mysql, MYSQL_OPT_NONBLOCK, NULL) != 0) {
        return my_conn_fail(sess, conn);
    }
    sess->protocol = MYSQL_PROTOCOL_TCP;
    if (my.mysql_options(sess->mysql, MYSQL_OPT_PROTOCOL, &sess->protocol) != 0) {
        return my_conn_fail(sess, conn);
    }
    if (conn->ssl_mode == KILN_DB_SSL_VERIFY_FULL) {
        sess->verify = 1;
        if (my.mysql_ssl_set(sess->mysql, NULL, NULL, conn->ca_path, NULL, NULL) != 0) {
            return my_conn_fail(sess, conn);
        }
        if (my.mysql_options(sess->mysql, MYSQL_OPT_SSL_VERIFY_SERVER_CERT, &sess->verify) != 0) {
            return my_conn_fail(sess, conn);
        }
    } else if (my_plain(sess) != 0) {
        return my_conn_fail(sess, conn);
    }
    sess->connect_ret = NULL;
    sess->phase = MY_CONNECT;
    sess->status = my.mysql_real_connect_start(&sess->connect_ret, sess->mysql, host, conn->user,
        conn->pass, conn->database, (unsigned int)conn->port, NULL, flags);
    if (sess->status) {
        return my_park(sess, conn, sess->status);
    }
    return my_after_connect(sess, conn);
}

static int my_begin_query(my_sess *sess, kiln_db_conn *conn, const char *sql, size_t len) {
    if (!sql) {
        return my_fail(sess, conn, KILN_DB_CONFIG, 0, NULL, "missing sql");
    }
    sess->query = sql;
    sess->query_len = (unsigned long)len;
    sess->phase = MY_QUERY;
    my_arm_socket(sess->mysql);
    sess->status =
        my.mysql_real_query_start(&sess->iret, sess->mysql, sess->query, sess->query_len);
    if (sess->status) {
        return my_park(sess, conn, sess->status);
    }
    return my_after_query(sess, conn);
}

static uint64_t my_hash(const char *sql, size_t len) {
    uint64_t h = 14695981039346656037ull;
    size_t i;
    for (i = 0; i < len; i++) {
        h ^= (unsigned char)sql[i];
        h *= 1099511628211ull;
    }
    return h;
}

static int my_grave_room(my_sess *sess, int want) {
    MYSQL_STMT **next;
    if (want <= 0 || (size_t)want > SIZE_MAX / sizeof *next) {
        return 0;
    }
    if (want <= sess->grave_cap) {
        return 1;
    }
    next = realloc(sess->grave, (size_t)want * sizeof *next);
    if (!next) {
        return 0;
    }
    sess->grave = next;
    sess->grave_cap = want;
    return 1;
}

static void my_grave(my_sess *sess, MYSQL_STMT *stmt) {
    int i;
    if (!stmt) {
        return;
    }
    for (i = 0; i < sess->ngrave; i++) {
        if (sess->grave[i] == stmt) {
            return;
        }
    }
    if (sess->ngrave == sess->grave_cap) {
        if (sess->grave_cap > INT_MAX / 2) {
            return;
        }
        if (!my_grave_room(sess, sess->grave_cap ? sess->grave_cap * 2 : 8)) {
            return;
        }
    }
    sess->grave[sess->ngrave++] = stmt;
}

static int my_graved(const my_sess *sess, MYSQL_STMT *stmt) {
    int i;
    for (i = 0; i < sess->ngrave; i++) {
        if (sess->grave[i] == stmt) {
            return 1;
        }
    }
    return 0;
}

static int my_cache_contains(const my_sess *sess, MYSQL_STMT *stmt) {
    int i;
    if (!stmt || !sess->slots) {
        return 0;
    }
    for (i = 0; i < sess->cap; i++) {
        if (sess->slots[i].stmt == stmt) {
            return 1;
        }
    }
    return 0;
}

static void my_cache_invalidate(my_sess *sess) {
    int i;
    if (!sess) {
        return;
    }
    for (i = 0; i < sess->close_n; i++) {
        my_grave(sess, sess->close_q[i]);
    }
    sess->close_n = 0;
    sess->close_prepare = 0;
    sess->hit_stmt = NULL;
    sess->prepare_exec = 0;
    sess->reprepare = 0;
    if (sess->stmt) {
        my_grave(sess, sess->stmt);
        sess->stmt = NULL;
    }
    if (sess->slots) {
        for (i = 0; i < sess->cap; i++) {
            free(sess->slots[i].sql);
            sess->slots[i].sql = NULL;
            sess->slots[i].len = 0;
            sess->slots[i].hash = 0;
            sess->slots[i].unread = 0;
            sess->slots[i].stamp = 0;
            if (sess->slots[i].stmt) {
                my_grave(sess, sess->slots[i].stmt);
                sess->slots[i].stmt = NULL;
            }
        }
    }
    sess->used = 0;
}

static int my_cache_ensure(my_sess *sess, kiln_db_conn *conn) {
    int cap = conn->stmt_cache;
    if (cap < 0) {
        cap = 0;
    }
    if (cap > 256) {
        cap = 256;
    }
    if (!my_grave_room(sess, cap + 8)) {
        return 0;
    }
    if (sess->slots) {
        return 1;
    }
    if (sess->cache_set && sess->cap == cap) {
        return 1;
    }
    sess->cap = cap;
    sess->cache_set = 1;
    if (cap == 0) {
        return 1;
    }
    sess->slots = calloc((size_t)cap, sizeof *sess->slots);
    return sess->slots != NULL;
}

static my_stmt_ent *my_cache_find(my_sess *sess, const char *sql, size_t len) {
    uint64_t hash;
    int i;
    if (!sess->slots || !sql) {
        return NULL;
    }
    hash = my_hash(sql, len);
    for (i = 0; i < sess->cap; i++) {
        my_stmt_ent *slot = &sess->slots[i];
        if (!slot->sql || slot->len != len || slot->hash != hash) {
            continue;
        }
        if (len == 0 || memcmp(slot->sql, sql, len) == 0) {
            return slot;
        }
    }
    return NULL;
}

static my_stmt_ent *my_cache_by_stmt(my_sess *sess, MYSQL_STMT *stmt) {
    int i;
    if (!sess->slots || !stmt) {
        return NULL;
    }
    for (i = 0; i < sess->cap; i++) {
        if (sess->slots[i].stmt == stmt) {
            return &sess->slots[i];
        }
    }
    return NULL;
}

static void my_cache_forget_stmt(my_sess *sess, MYSQL_STMT *stmt) {
    int i;
    if (!sess->slots || !stmt) {
        return;
    }
    for (i = 0; i < sess->cap; i++) {
        if (sess->slots[i].stmt != stmt) {
            continue;
        }
        free(sess->slots[i].sql);
        sess->slots[i].sql = NULL;
        sess->slots[i].stmt = NULL;
        sess->slots[i].len = 0;
        sess->slots[i].hash = 0;
        sess->slots[i].unread = 0;
        sess->slots[i].stamp = 0;
        if (sess->used > 0) {
            sess->used--;
        }
    }
}

static void my_note_unread(my_sess *sess, kiln_db_conn *conn) {
    int i;
    if (!sess->slots || !sess->stmt) {
        return;
    }
    for (i = 0; i < sess->cap; i++) {
        if (sess->slots[i].stmt == sess->stmt) {
            sess->slots[i].unread = conn->fetch_done ? 0 : 1;
        }
    }
}

static my_stmt_ent *my_cache_lru(my_sess *sess, int allow_current) {
    my_stmt_ent *best = NULL;
    int i;
    if (!sess->slots) {
        return NULL;
    }
    for (i = 0; i < sess->cap; i++) {
        my_stmt_ent *slot = &sess->slots[i];
        if (!slot->stmt || !slot->sql || slot->unread) {
            continue;
        }
        if (!allow_current && slot->stmt == sess->stmt) {
            continue;
        }
        if (!best || slot->stamp < best->stamp) {
            best = slot;
        }
    }
    return best;
}

static int my_cache_store(my_sess *sess, kiln_db_conn *conn) {
    my_stmt_ent *slot = NULL;
    char *copy;
    size_t len;
    int i;
    if (!sess->slots || sess->cap <= 0 || !sess->stmt || !conn->sql) {
        return 1;
    }
    for (i = 0; i < sess->cap; i++) {
        if (sess->slots[i].stmt == sess->stmt) {
            sess->slots[i].stamp = ++sess->clock;
            return 1;
        }
    }
    if (sess->used >= sess->cap) {
        return 1;
    }
    for (i = 0; i < sess->cap; i++) {
        if (!sess->slots[i].stmt && !sess->slots[i].sql) {
            slot = &sess->slots[i];
            break;
        }
    }
    if (!slot) {
        return 1;
    }
    len = conn->sql_len;
    copy = malloc(len + 1);
    if (!copy) {
        return 0;
    }
    if (len) {
        memcpy(copy, conn->sql, len);
    }
    copy[len] = 0;
    slot->hash = my_hash(copy, len);
    slot->sql = copy;
    slot->len = len;
    slot->stmt = sess->stmt;
    slot->stamp = ++sess->clock;
    slot->unread = 0;
    sess->used++;
    return 1;
}

static int my_queue_close(my_sess *sess, MYSQL_STMT *stmt) {
    int i;
    if (!stmt) {
        return 1;
    }
    for (i = 0; i < sess->close_n; i++) {
        if (sess->close_q[i] == stmt) {
            return 1;
        }
    }
    if (sess->close_n >= 4) {
        return 0;
    }
    sess->close_q[sess->close_n++] = stmt;
    return 1;
}

static int my_apply_hit(my_sess *sess, kiln_db_conn *conn, my_stmt_ent *hit) {
    sess->stmt = hit->stmt;
    hit->stamp = ++sess->clock;
    if (conn->fetch_done) {
        hit->unread = 0;
    }
    conn->prepared = 1;
    sess->phase = MY_IDLE;
    conn->wait_kind = 0;
    conn->fd = (int)my.mysql_get_socket(sess->mysql);
    return KILN_DB_STEP_DONE;
}

static int my_prepare_handle(my_sess *sess, kiln_db_conn *conn, int make_new) {
    conn->prepared = 0;
    my_free_results(sess);
    if (make_new) {
        sess->stmt = my.mysql_stmt_init(sess->mysql);
        if (!sess->stmt) {
            return my_conn_fail(sess, conn);
        }
    }
    if (!sess->stmt) {
        return my_fail(sess, conn, KILN_DB_ERR, 0, NULL, "statement");
    }
    sess->phase = MY_PREPARE;
    my_arm_socket(sess->mysql);
    sess->status = my.mysql_stmt_prepare_start(
        &sess->iret, sess->stmt, conn->sql, (unsigned long)conn->sql_len);
    if (sess->status) {
        return my_park(sess, conn, sess->status);
    }
    return my_after_prepare(sess, conn);
}

static int my_after_closes(my_sess *sess, kiln_db_conn *conn) {
    int prepare = sess->close_prepare;
    MYSQL_STMT *hit = sess->hit_stmt;
    my_stmt_ent *ent;
    sess->close_prepare = 0;
    sess->hit_stmt = NULL;
    if (hit) {
        ent = my_cache_by_stmt(sess, hit);
        if (ent) {
            return my_apply_hit(sess, conn, ent);
        }
    }
    if (prepare) {
        return my_prepare_handle(sess, conn, 1);
    }
    sess->phase = MY_IDLE;
    conn->wait_kind = 0;
    if (sess->mysql) {
        conn->fd = (int)my.mysql_get_socket(sess->mysql);
    }
    return KILN_DB_STEP_DONE;
}

static int my_drain_closes(my_sess *sess, kiln_db_conn *conn) {
    while (sess->close_n > 0) {
        MYSQL_STMT *stmt = sess->close_q[0];
        int i;
        for (i = 1; i < sess->close_n; i++) {
            sess->close_q[i - 1] = sess->close_q[i];
        }
        sess->close_n--;
        sess->closing = stmt;
        sess->phase = MY_CLOSE_STMT;
        sess->bret = 0;
        my_arm_socket(sess->mysql);
        sess->status = my.mysql_stmt_close_start(&sess->bret, stmt);
        if (sess->status) {
            return my_park(sess, conn, sess->status);
        }
        sess->closing = NULL;
        if (sess->bret != 0) {
            conn->broken = 1;
            my_cache_invalidate(sess);
            return my_conn_fail(sess, conn);
        }
    }
    return my_after_closes(sess, conn);
}

static int my_prepare_miss(my_sess *sess, kiln_db_conn *conn) {
    my_stmt_ent *victim;
    if (sess->stmt && !my_cache_contains(sess, sess->stmt)) {
        if (!my_queue_close(sess, sess->stmt)) {
            return my_fail(sess, conn, KILN_DB_CAPACITY, 0, NULL, "statement cache");
        }
        sess->stmt = NULL;
    }
    if (sess->cap > 0 && sess->used >= sess->cap) {
        victim = my_cache_lru(sess, 0);
        if (!victim && conn->fetch_done) {
            victim = my_cache_lru(sess, 1);
        }
        if (victim && victim->stmt) {
            MYSQL_STMT *stmt = victim->stmt;
            free(victim->sql);
            victim->sql = NULL;
            victim->stmt = NULL;
            victim->len = 0;
            victim->hash = 0;
            victim->unread = 0;
            victim->stamp = 0;
            if (sess->used > 0) {
                sess->used--;
            }
            if (sess->stmt == stmt) {
                sess->stmt = NULL;
            }
            if (!my_queue_close(sess, stmt)) {
                my_grave(sess, stmt);
                return my_fail(sess, conn, KILN_DB_CAPACITY, 0, NULL, "statement cache");
            }
        }
    }
    sess->close_prepare = 1;
    sess->hit_stmt = NULL;
    if (sess->close_n > 0) {
        return my_drain_closes(sess, conn);
    }
    return my_prepare_handle(sess, conn, 1);
}

static int my_begin_prepare(my_sess *sess, kiln_db_conn *conn) {
    my_stmt_ent *hit;
    if (!conn->sql) {
        return my_fail(sess, conn, KILN_DB_CONFIG, 0, NULL, "missing sql");
    }
    if (!my_cache_ensure(sess, conn)) {
        return my_fail(sess, conn, KILN_DB_CAPACITY, 0, NULL, "statement cache");
    }
    my_note_unread(sess, conn);
    hit = my_cache_find(sess, conn->sql, conn->sql_len);
    if (hit && hit->stmt) {
        if (sess->stmt && sess->stmt != hit->stmt && !my_cache_contains(sess, sess->stmt)) {
            if (!my_queue_close(sess, sess->stmt)) {
                return my_fail(sess, conn, KILN_DB_CAPACITY, 0, NULL, "statement cache");
            }
            sess->stmt = NULL;
            sess->close_prepare = 1;
            sess->hit_stmt = hit->stmt;
            return my_drain_closes(sess, conn);
        }
        return my_apply_hit(sess, conn, hit);
    }
    return my_prepare_miss(sess, conn);
}

static int my_begin_exec(my_sess *sess, kiln_db_conn *conn) {
    int bound;
    if (!sess->stmt || !conn->prepared) {
        return my_begin_query(sess, conn, conn->sql, conn->sql_len);
    }
    if (sess->bind_phase != conn->setup_phase) {
        my_clear_params(sess);
        sess->bind_phase = conn->setup_phase;
    }
    bound = my_bind_params(sess);
    if (bound != KILN_DB_OK) {
        if (bound == KILN_DB_ERR) {
            return my_stmt_fail(sess, conn);
        }
        return my_fail(sess, conn, bound, 0, NULL, "bind count does not match placeholders");
    }
    my_free_results(sess);
    conn->fetch_done = 0;
    conn->rows_affected = 0;
    sess->phase = MY_EXEC;
    my_arm_socket(sess->mysql);
    sess->status = my.mysql_stmt_execute_start(&sess->iret, sess->stmt);
    if (sess->status) {
        return my_park(sess, conn, sess->status);
    }
    return my_after_exec(sess, conn);
}

static int my_begin_commit(my_sess *sess, kiln_db_conn *conn, int rollback) {
    sess->bret = 0;
    sess->phase = rollback ? MY_ROLLBACK : MY_COMMIT;
    my_arm_socket(sess->mysql);
    if (rollback) {
        sess->status = my.mysql_rollback_start(&sess->bret, sess->mysql);
    } else {
        sess->status = my.mysql_commit_start(&sess->bret, sess->mysql);
    }
    if (sess->status) {
        return my_park(sess, conn, sess->status);
    }
    return my_after_flag(sess, conn);
}

static int my_step(kiln_db_conn *conn, int ready_bits, int64_t deadline_ms) {
    my_sess *sess;
    (void)deadline_ms;
    sess = my_session(conn);
    if (!sess) {
        return my_fail(NULL, conn, KILN_DB_CAPACITY, 0, NULL, "session");
    }
    if (sess->phase != MY_IDLE) {
        if (conn->op == KILN_DB_OP_CANCEL) {
            kiln_db_fail(
                conn, KILN_DB_UNSUPPORTED, 0, NULL, "cancel is KILL QUERY on a second connection");
            return KILN_DB_STEP_ERR;
        }
        return my_resume(sess, conn, ready_bits);
    }
    if (!sess->mysql && conn->op != KILN_DB_OP_CONNECT) {
        return my_fail(sess, conn, KILN_DB_CONN, 0, NULL, "not connected");
    }
    if (conn->op == KILN_DB_OP_CONNECT) {
        return my_begin_connect(sess, conn);
    }
    if (conn->op == KILN_DB_OP_CANCEL) {
        kiln_db_fail(
            conn, KILN_DB_UNSUPPORTED, 0, NULL, "cancel is KILL QUERY on a second connection");
        return KILN_DB_STEP_ERR;
    }
    if (conn->op == KILN_DB_OP_DRAIN) {
        if (!sess->stmt || !conn->prepared || conn->fetch_done) {
            conn->fetch_done = 1;
            conn->wait_kind = 0;
            return KILN_DB_STEP_DONE;
        }
        return my_begin_fetch(sess, conn);
    }
    if (conn->op == KILN_DB_OP_PREPARE) {
        return my_begin_prepare(sess, conn);
    }
    if (conn->op == KILN_DB_OP_EXEC) {
        return my_begin_exec(sess, conn);
    }
    if (conn->op == KILN_DB_OP_BEGIN) {
        return my_begin_query(sess, conn, my_begin_sql, sizeof my_begin_sql - 1);
    }
    if (conn->op == KILN_DB_OP_COMMIT) {
        return my_begin_commit(sess, conn, 0);
    }
    if (conn->op == KILN_DB_OP_ROLLBACK) {
        return my_begin_commit(sess, conn, 1);
    }
    if (conn->op == KILN_DB_OP_COPY_IN) {
        return my_fail(sess, conn, KILN_DB_UNSUPPORTED, 0, NULL, "copy");
    }
    return my_fail(sess, conn, KILN_DB_UNSUPPORTED, 0, NULL, "mysql op");
}

static void my_release(kiln_db_conn *conn) {
    my_sess *sess = conn->native;
    int i;
    if (!sess) {
        return;
    }
    if (sess->closing) {
        sess->closing->mysql = NULL;
    }
    if (sess->mysql) {
        my.mysql_close(sess->mysql);
        sess->mysql = NULL;
    }
    if (sess->stmt && !my_cache_contains(sess, sess->stmt) && !my_graved(sess, sess->stmt)) {
        my.mysql_stmt_close(sess->stmt);
    }
    sess->stmt = NULL;
    if (sess->closing && !my_cache_contains(sess, sess->closing) && !my_graved(sess, sess->closing)) {
        my.mysql_stmt_close(sess->closing);
    }
    sess->closing = NULL;
    for (i = 0; i < sess->close_n; i++) {
        if (!my_cache_contains(sess, sess->close_q[i]) && !my_graved(sess, sess->close_q[i])) {
            my.mysql_stmt_close(sess->close_q[i]);
        }
    }
    sess->close_n = 0;
    if (sess->slots) {
        for (i = 0; i < sess->cap; i++) {
            if (sess->slots[i].stmt) {
                my.mysql_stmt_close(sess->slots[i].stmt);
            }
            free(sess->slots[i].sql);
        }
    }
    for (i = 0; i < sess->ngrave; i++) {
        my.mysql_stmt_close(sess->grave[i]);
    }
    free(sess->slots);
    free(sess->grave);
    my_free_results(sess);
    my_drop_params(sess);
    free(sess->big);
    free(sess->batch);
    free(sess->cell_len);
    free(sess->row_start);
    free(sess);
    conn->native = NULL;
    conn->prepared = 0;
    conn->res = NULL;
    conn->cancel = NULL;
}

int kiln_db_my_bind_str(
    kiln_db_conn *conn, uint32_t index, const char *data, long n, int is_null, int format) {
    my_sess *sess = my_session(conn);
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
        my_clear_params(sess);
        sess->bind_phase = conn->setup_phase;
    }
    if (my_reserve_params(sess, (int)index + 1) != KILN_DB_OK) {
        return KILN_DB_CAPACITY;
    }
    while (sess->nparams < (int)index + 1) {
        sess->param_buf[sess->nparams] = NULL;
        sess->param_len[sess->nparams] = 0;
        sess->param_null[sess->nparams] = 1;
        sess->param_format[sess->nparams] = 0;
        sess->nparams++;
    }
    free(sess->param_buf[index]);
    sess->param_buf[index] = NULL;
    sess->param_len[index] = 0;
    sess->param_null[index] = 1;
    sess->param_format[index] = format ? 1 : 0;
    if (!is_null) {
        copy = malloc((size_t)n + 1u);
        if (!copy) {
            return KILN_DB_CAPACITY;
        }
        if (n > 0) {
            memcpy(copy, data, (size_t)n);
        }
        copy[n] = 0;
        sess->param_buf[index] = copy;
        sess->param_len[index] = (unsigned long)n;
        sess->param_null[index] = 0;
    }
    return KILN_DB_OK;
}

int kiln_db_my_result_meta(kiln_db_conn *conn, int64_t *out, int n) {
    my_sess *sess = conn->native;
    if (!out || n < 5) {
        return KILN_DB_ERR;
    }
    out[0] = sess ? sess->ncols : 0;
    out[1] = sess ? sess->rows : 0;
    out[2] = conn->fetch_done ? 1 : 0;
    out[3] = conn->rows_affected;
    out[4] = sess ? sess->warnings : 0;
    return KILN_DB_OK;
}

int kiln_db_my_result_types(kiln_db_conn *conn, int64_t *out, int n) {
    my_sess *sess = conn->native;
    int i;
    if (!out || n < 0) {
        return KILN_DB_ERR;
    }
    if (!sess) {
        return KILN_DB_OK;
    }
    for (i = 0; i < sess->ncols && i < n; i++) {
        out[i] = sess->rtype[i];
    }
    return sess->ncols > n ? KILN_DB_CAPACITY : KILN_DB_OK;
}

static int my_format_store(
    int store, const char *raw, char *tmp, size_t tmp_n, const char **out, size_t *out_n) {
    int n;
    if (!raw || !tmp || tmp_n < 2) {
        return 0;
    }
    if (store == MY_STORE_I64) {
        int64_t value;
        memcpy(&value, raw, 8);
        n = kiln_db_format_i64(value, tmp, tmp_n);
    } else if (store == MY_STORE_F64) {
        double value;
        memcpy(&value, raw, 8);
        n = kiln_db_format_f64(value, tmp, tmp_n);
    } else {
        return 0;
    }
    if (n <= 0) {
        return 0;
    }
    *out = tmp;
    *out_n = (size_t)n;
    return 1;
}

static const char *my_row_text(kiln_db_conn *conn, uint32_t row, int64_t *lens, int n) {
    static __thread char empty[1];
    my_sess *sess = conn->native;
    char *buf = NULL;
    size_t used = 0;
    size_t off;
    int i;
    empty[0] = 0;
    sp_ffi_bin_len = 0;
    if (!sess || !lens || row >= sess->rows || sess->ncols <= 0 || sess->ncols > n) {
        if (lens && n > 0) {
            lens[0] = -2;
        }
        return empty;
    }
    off = sess->row_start[row];
    for (i = 0; i < sess->ncols; i++) {
        int64_t clen = sess->cell_len[((size_t)row * (size_t)sess->ncols) + (size_t)i];
        char tmp[64];
        const char *src;
        size_t len;
        int store = sess->rstore ? sess->rstore[i] : MY_STORE_TEXT;
        if (clen < 0) {
            lens[i] = -1;
            continue;
        }
        if (store != MY_STORE_TEXT) {
            if (!sess->batch ||
                !my_format_store(store, sess->batch + off, tmp, sizeof tmp, &src, &len)) {
                lens[0] = -2;
                return empty;
            }
        } else {
            len = (size_t)clen;
            src = sess->batch ? sess->batch + off : NULL;
            if (len && !src) {
                lens[0] = -2;
                return empty;
            }
        }
        if (len > INT_MAX || used > (size_t)INT_MAX - len) {
            lens[0] = -2;
            return empty;
        }
        buf = kiln_db_thread_room(used + len + 1);
        if (!buf) {
            lens[0] = -2;
            return empty;
        }
        if (len) {
            memcpy(buf + used, src, len);
        }
        lens[i] = (int64_t)len;
        used += len;
        off += (size_t)clen;
    }
    if (used == 0) {
        return empty;
    }
    buf = kiln_db_thread_room(used + 1);
    if (!buf) {
        lens[0] = -2;
        return empty;
    }
    buf[used] = 0;
    sp_ffi_bin_len = (int)used;
    return buf;
}

static const char *my_rows_emit(kiln_db_conn *conn, uint32_t first, uint32_t max_rows,
    size_t max_bytes, int64_t *lens, int lens_cap, int64_t *nums, double *floats, int64_t *meta,
    int typed) {
    static __thread char empty[1];
    my_sess *sess = conn ? conn->native : NULL;
    uint32_t taken = 0;
    size_t used = 0;
    empty[0] = 0;
    if (!meta) {
        return empty;
    }
    if (!sess || first >= sess->rows || sess->ncols <= 0 || !lens) {
        meta[0] = 0;
        return empty;
    }
    if (sess->ncols >= lens_cap) {
        return empty;
    }
    while (first + taken < sess->rows && taken < max_rows &&
           (int64_t)(taken + 1) * (sess->ncols + 1) <= lens_cap) {
        uint32_t row = first + taken;
        size_t base = (size_t)taken * (size_t)(sess->ncols + 1);
        size_t start = used;
        size_t off = sess->row_start[row];
        int c;
        int ok = 1;
        for (c = 0; c < sess->ncols; c++) {
            size_t slot = base + (size_t)c;
            int64_t clen = sess->cell_len[((size_t)row * (size_t)sess->ncols) + (size_t)c];
            char tmp[64];
            const char *src;
            size_t len;
            int store = sess->rstore ? sess->rstore[c] : MY_STORE_TEXT;
            if (clen < 0) {
                lens[slot] = -1;
                continue;
            }
            if (typed && store == MY_STORE_I64) {
                int64_t value;
                if (!sess->batch || clen < 8 || !nums) {
                    ok = 0;
                    break;
                }
                memcpy(&value, sess->batch + off, 8);
                lens[slot] = -3;
                nums[slot] = value;
                off += (size_t)clen;
                continue;
            }
            if (typed && store == MY_STORE_F64) {
                double value;
                if (!sess->batch || clen < 8 || !floats) {
                    ok = 0;
                    break;
                }
                memcpy(&value, sess->batch + off, 8);
                lens[slot] = -4;
                floats[slot] = value;
                off += (size_t)clen;
                continue;
            }
            if (store != MY_STORE_TEXT) {
                if (!sess->batch ||
                    !my_format_store(store, sess->batch + off, tmp, sizeof tmp, &src, &len)) {
                    ok = 0;
                    break;
                }
            } else {
                len = (size_t)clen;
                src = sess->batch ? sess->batch + off : NULL;
                if (len && !src) {
                    ok = 0;
                    break;
                }
            }
            if (len > INT_MAX || used > (size_t)INT_MAX - len) {
                ok = 0;
                break;
            }
            if (len) {
                char *buf = kiln_db_thread_room(used + len + 1);
                if (!buf) {
                    ok = 0;
                    break;
                }
                memcpy(buf + used, src, len);
            }
            lens[slot] = (int64_t)len;
            used += len;
            off += (size_t)clen;
        }
        if (!ok) {
            return empty;
        }
        if (taken > 0 && used > max_bytes) {
            used = start;
            break;
        }
        lens[base + (size_t)sess->ncols] = (int64_t)(used - start);
        taken++;
    }
    meta[0] = taken;
    meta[1] = (int64_t)used;
    meta[2] = sess->ncols;
    sp_ffi_bin_len = (int)used;
    if (used == 0) {
        return empty;
    }
    return kiln_db_thread_room(used + 1);
}

const char *kiln_db_my_result_row(kiln_db_conn *conn, uint32_t row, int64_t *lens, int n) {
    static __thread char empty[1];
    my_sess *sess = conn->native;
    int i;
    if (sess && sess->has_store) {
        return my_row_text(conn, row, lens, n);
    }
    empty[0] = 0;
    sp_ffi_bin_len = 0;
    if (!sess || !lens || row >= sess->rows || sess->ncols > n || !sess->batch) {
        if (lens && n > 0) {
            lens[0] = -2;
        }
        return empty;
    }
    for (i = 0; i < sess->ncols; i++) {
        lens[i] = sess->cell_len[((size_t)row * (size_t)sess->ncols) + (size_t)i];
    }
    sp_ffi_bin_len = (int)(sess->row_start[row + 1] - sess->row_start[row]);
    return sess->batch + sess->row_start[row];
}

const char *kiln_db_my_result_bytes(
    kiln_db_conn *conn, uint32_t row, uint32_t col, int64_t *meta, int meta_n) {
    static __thread char empty[1];
    my_sess *sess = conn->native;
    size_t off;
    int c;
    int64_t len;
    empty[0] = 0;
    if (meta && meta_n > 0) {
        meta[0] = 1;
    }
    if (meta && meta_n > 1) {
        meta[1] = 0;
    }
    sp_ffi_bin_len = 0;
    if (!sess || row >= sess->rows || col >= (uint32_t)sess->ncols || !sess->batch) {
        return empty;
    }
    off = sess->row_start[row];
    for (c = 0; c < (int)col; c++) {
        int64_t l = sess->cell_len[((size_t)row * (size_t)sess->ncols) + (size_t)c];
        if (l > 0) {
            off += (size_t)l;
        }
    }
    len = sess->cell_len[((size_t)row * (size_t)sess->ncols) + col];
    if (len < 0) {
        return empty;
    }
    if (sess->has_store && sess->rstore && sess->rstore[col] != MY_STORE_TEXT) {
        char tmp[64];
        const char *text;
        size_t ntext;
        char *room;
        if (!my_format_store(
                sess->rstore[col], sess->batch + off, tmp, sizeof tmp, &text, &ntext)) {
            return empty;
        }
        room = kiln_db_thread_room(ntext + 1);
        if (!room) {
            return empty;
        }
        memcpy(room, text, ntext);
        room[ntext] = 0;
        if (meta && meta_n > 0) {
            meta[0] = 0;
        }
        if (meta && meta_n > 1) {
            meta[1] = (int64_t)ntext;
        }
        sp_ffi_bin_len = (int)ntext;
        return room;
    }
    if (meta && meta_n > 0) {
        meta[0] = 0;
    }
    if (meta && meta_n > 1) {
        meta[1] = len;
    }
    sp_ffi_bin_len = (int)len;
    return sess->batch + off;
}

const char *kiln_db_my_result_rows(kiln_db_conn *conn, uint32_t first, uint32_t max_rows,
    size_t max_bytes, int64_t *lens, int lens_cap, int64_t *meta) {
    static __thread char empty[1];
    my_sess *sess = conn->native;
    uint32_t last;
    uint32_t row;
    size_t bytes;
    char *buf;
    if (sess && sess->has_store) {
        return my_rows_emit(conn, first, max_rows, max_bytes, lens, lens_cap, NULL, NULL, meta, 0);
    }
    empty[0] = 0;
    if (!sess || first >= sess->rows || sess->ncols <= 0 || !sess->batch) {
        meta[0] = 0;
        return empty;
    }
    if (sess->ncols >= lens_cap) {
        return empty;
    }
    last = first + 1;
    while (last < sess->rows && last - first < max_rows &&
           (int64_t)(last - first + 1) * (sess->ncols + 1) <= lens_cap &&
           sess->row_start[last + 1] - sess->row_start[first] <= max_bytes) {
        last++;
    }
    bytes = sess->row_start[last] - sess->row_start[first];
    if (bytes > INT_MAX) {
        return empty;
    }
    buf = kiln_db_thread_room(bytes + 1);
    if (!buf) {
        return empty;
    }
    if (bytes) {
        memcpy(buf, sess->batch + sess->row_start[first], bytes);
    }
    for (row = first; row < last; row++) {
        size_t base = (size_t)(row - first) * (size_t)(sess->ncols + 1);
        memcpy(lens + base, sess->cell_len + ((size_t)row * (size_t)sess->ncols),
            (size_t)sess->ncols * sizeof *lens);
        lens[base + (size_t)sess->ncols] = (int64_t)(sess->row_start[row + 1] - sess->row_start[row]);
    }
    meta[0] = last - first;
    meta[1] = (int64_t)bytes;
    meta[2] = sess->ncols;
    sp_ffi_bin_len = (int)bytes;
    return buf;
}

const char *kiln_db_my_result_rows_typed(kiln_db_conn *conn, uint32_t first, uint32_t max_rows,
    size_t max_bytes, int64_t *lens, int lens_cap, int64_t *nums, double *floats, int64_t *meta) {
    my_sess *sess = conn ? conn->native : NULL;
    if (!sess || !sess->has_store) {
        return kiln_db_my_result_rows(conn, first, max_rows, max_bytes, lens, lens_cap, meta);
    }
    return my_rows_emit(conn, first, max_rows, max_bytes, lens, lens_cap, nums, floats, meta, 1);
}
