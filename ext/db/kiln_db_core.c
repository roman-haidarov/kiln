#include "kiln_db.h"

#include <stdio.h>
#include <float.h>
#include <limits.h>
#include <arpa/inet.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define DNS_NAME_MAX 253

static kiln_db_step_fn step_of[3];
static kiln_db_release_fn release_of[3];
static char load_error[256];

void kiln_db_set_load_error(const char *text) {
    if (!text) {
        load_error[0] = 0;
        return;
    }
    snprintf(load_error, sizeof load_error, "%s", text);
}

const char *kiln_db_load_error(void) {
    sp_ffi_bin_len = (int)strlen(load_error);
    return load_error;
}

void kiln_db_driver_register(int kind, kiln_db_step_fn step, kiln_db_release_fn release) {
    if (kind != KILN_DB_KIND_PG && kind != KILN_DB_KIND_MY) {
        return;
    }
    step_of[kind] = step;
    release_of[kind] = release;
}

int kiln_db_load_kind(int kind) {
    if (kind == KILN_DB_KIND_PG) {
        return kiln_db_pg_load();
    }
    if (kind == KILN_DB_KIND_MY) {
        return kiln_db_my_load();
    }
    return KILN_DB_CONFIG;
}

long kiln_db_client_version(int kind) {
    if (kind == KILN_DB_KIND_PG) {
        return kiln_db_pg_client_version();
    }
    if (kind == KILN_DB_KIND_MY) {
        return kiln_db_my_client_version();
    }
    return 0;
}

uint64_t kiln_db_caps(int kind) {
    if (kind == KILN_DB_KIND_PG && kiln_db_pg_client_version() >= 170000) {
        return KILN_DB_CAP_CHUNKED_ROWS;
    }
    return 0;
}

int kiln_db_configure_values(const int64_t *values, int n) {
    kiln_db_limits next;
    int i;
    if (!values || n != KILN_DB_CONFIG_VALUE_COUNT) {
        return KILN_DB_CONFIG;
    }
    for (i = 0; i < KILN_DB_CONFIG_VALUE_COUNT; i++) {
        if (values[i] <= 0 || (uint64_t)values[i] > UINT32_MAX) {
            return KILN_DB_CONFIG;
        }
    }
    next.max_live_slots = (uint32_t)values[0];
    next.block_rows = (uint32_t)values[1];
    next.max_error_bytes = (uint32_t)values[2];
    next.max_payload_bytes = (uint32_t)values[3];
    next.max_resolver_queue = (uint32_t)values[4];
    next.max_pipeline_inflight = (uint32_t)values[5];
    next.max_dirty_groups = (uint32_t)values[6];
    next.copy_min_rows = (uint32_t)values[7];
    return kiln_db_configure(&next);
}

int64_t kiln_db_now_ms(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        return 0;
    }
    return ((int64_t)ts.tv_sec * 1000) + (int64_t)(ts.tv_nsec / 1000000L);
}

static int dup_text(char **dst, const char *src, size_t len) {
    const kiln_db_limits *limits = kiln_db_limits_get();
    char *copy;
    if (!limits) {
        return KILN_DB_CONFIG;
    }
    if (len > limits->max_payload_bytes) {
        return KILN_DB_CAPACITY;
    }
    if (len && (!src || memchr(src, 0, len))) {
        return KILN_DB_ERR;
    }
    if (len > SIZE_MAX - 1) {
        return KILN_DB_CAPACITY;
    }
    copy = malloc(len + 1);
    if (!copy) {
        return KILN_DB_CAPACITY;
    }
    if (len) {
        memcpy(copy, src, len);
    }
    copy[len] = 0;
    free(*dst);
    *dst = copy;
    return KILN_DB_OK;
}

static int loopback_host(const char *host) {
    return host && (strcmp(host, "127.0.0.1") == 0 || strcmp(host, "::1") == 0);
}

static void wipe_text(char *text) {
    volatile char *p = text;
    if (!text) {
        return;
    }
    while (*p) {
        *p++ = 0;
    }
}

static void conn_clear(kiln_db_conn *conn) {
    wipe_text(conn->pass);
    free(conn->error);
    free(conn->host);
    free(conn->hostaddr);
    free(conn->user);
    free(conn->pass);
    free(conn->database);
    free(conn->ca_path);
    free(conn->tls_name);
    free(conn->sql);
    free(conn);
}

uint64_t kiln_db_conn_create(int kind, uint64_t scope, uint64_t thread_id, int64_t *err) {
    kiln_db_conn *conn;
    uint64_t handle;
    int local = KILN_DB_OK;
    if (kind != KILN_DB_KIND_PG && kind != KILN_DB_KIND_MY) {
        if (err) {
            *err = KILN_DB_CONFIG;
        }
        return 0;
    }
    conn = calloc(1, sizeof *conn);
    if (!conn) {
        if (err) {
            *err = KILN_DB_CAPACITY;
        }
        return 0;
    }
    conn->kind = kind;
    conn->scope = scope;
    conn->thread_id = thread_id;
    conn->fd = -1;
    conn->ssl_mode = KILN_DB_SSL_VERIFY_FULL;
    handle = kiln_db_slot_put(KILN_DB_SLOT_CONN, conn, scope, thread_id, &local);
    if (!handle) {
        free(conn);
        if (err) {
            *err = local;
        }
        return 0;
    }
    conn->slot = (uint32_t)handle;
    conn->generation = (uint32_t)(handle >> 32);
    if (err) {
        *err = KILN_DB_OK;
    }
    return handle;
}

static __thread uint64_t kiln_db_held_handle;
static __thread uint64_t kiln_db_held_scope;
static __thread uint64_t kiln_db_held_thread;
static __thread kiln_db_conn *kiln_db_held_conn;

kiln_db_conn *kiln_db_conn_get(uint64_t handle, uint64_t scope, uint64_t thread_id, int *err) {
    if (kiln_db_held_conn && handle == kiln_db_held_handle && scope == kiln_db_held_scope &&
        thread_id == kiln_db_held_thread) {
        if (err) {
            *err = KILN_DB_OK;
        }
        return kiln_db_held_conn;
    }
    return kiln_db_slot_use(handle, KILN_DB_SLOT_CONN, scope, thread_id, err);
}

int kiln_db_conn_set_impl(uint64_t handle, uint64_t scope, uint64_t thread_id, const char *host,
    size_t host_len, int port, const char *user, size_t user_len, const char *pass, size_t pass_len,
    const char *database, size_t database_len, int ssl_mode, const char *ca, size_t ca_len,
    int allow_insecure, const char *tls_name, size_t tls_name_len) {
    kiln_db_conn *conn;
    int err = KILN_DB_OK;
    int rc;
    conn = kiln_db_conn_get(handle, scope, thread_id, &err);
    if (!conn) {
        return err;
    }
    if (conn->active_op) {
        return KILN_DB_BUSY;
    }
    if (port <= 0 || port > UINT16_MAX) {
        return KILN_DB_CONFIG;
    }
    if (ssl_mode != KILN_DB_SSL_VERIFY_FULL && ssl_mode != KILN_DB_SSL_DISABLE) {
        return KILN_DB_CONFIG;
    }
    if (ssl_mode == KILN_DB_SSL_DISABLE) {
        if (!allow_insecure || host_len == 0 || host_len > DNS_NAME_MAX || !host ||
            memchr(host, 0, host_len)) {
            return KILN_DB_CONFIG;
        }
        if (!(host_len == 9 && memcmp(host, "127.0.0.1", 9) == 0) &&
            !(host_len == 3 && memcmp(host, "::1", 3) == 0)) {
            return KILN_DB_CONFIG;
        }
    } else if (ca_len == 0 || tls_name_len == 0 || !ca || !tls_name) {
        return KILN_DB_CONFIG;
    }
    rc = dup_text(&conn->host, host, host_len);
    if (rc != KILN_DB_OK) {
        return rc;
    }
    rc = dup_text(&conn->user, user, user_len);
    if (rc != KILN_DB_OK) {
        return rc;
    }
    rc = dup_text(&conn->pass, pass, pass_len);
    if (rc != KILN_DB_OK) {
        return rc;
    }
    rc = dup_text(&conn->database, database, database_len);
    if (rc != KILN_DB_OK) {
        return rc;
    }
    if (ssl_mode == KILN_DB_SSL_DISABLE) {
        if (!allow_insecure || !loopback_host(conn->host)) {
            return KILN_DB_CONFIG;
        }
        free(conn->ca_path);
        conn->ca_path = NULL;
        free(conn->tls_name);
        conn->tls_name = NULL;
    } else {
        rc = dup_text(&conn->ca_path, ca, ca_len);
        if (rc != KILN_DB_OK) {
            return rc;
        }
        rc = dup_text(&conn->tls_name, tls_name, tls_name_len);
        if (rc != KILN_DB_OK) {
            return rc;
        }
    }
    conn->port = port;
    conn->ssl_mode = ssl_mode;
    conn->insecure_ok = allow_insecure ? 1 : 0;
    return KILN_DB_OK;
}

int kiln_db_set_sql_impl(
    uint64_t handle, uint64_t scope, uint64_t thread_id, const char *sql, size_t sql_len) {
    const kiln_db_limits *limits = kiln_db_limits_get();
    kiln_db_conn *conn;
    int err = KILN_DB_OK;
    char *copy;
    conn = kiln_db_conn_get(handle, scope, thread_id, &err);
    if (!conn) {
        return err;
    }
    if (conn->active_op) {
        return KILN_DB_BUSY;
    }
    if (!limits) {
        return KILN_DB_CONFIG;
    }
    if (sql_len > limits->max_payload_bytes || sql_len > SIZE_MAX - 1) {
        return KILN_DB_CAPACITY;
    }
    if (sql_len && (!sql || memchr(sql, 0, sql_len))) {
        return KILN_DB_ERR;
    }
    copy = malloc(sql_len + 1);
    if (!copy) {
        return KILN_DB_CAPACITY;
    }
    if (sql_len) {
        memcpy(copy, sql, sql_len);
    }
    copy[sql_len] = 0;
    free(conn->sql);
    conn->sql = copy;
    conn->sql_len = sql_len;
    conn->prepared = 0;
    if (conn->setup_phase < INT_MAX) {
        conn->setup_phase++;
    }
    return KILN_DB_OK;
}

int kiln_db_set_format_impl(
    uint64_t handle, uint64_t scope, uint64_t thread_id, int format, int chunk) {
    kiln_db_conn *conn;
    int err = KILN_DB_OK;
    conn = kiln_db_conn_get(handle, scope, thread_id, &err);
    if (!conn) {
        return err;
    }
    if (conn->active_op) {
        return KILN_DB_BUSY;
    }
    if ((format != 0 && format != 1) || chunk < 0) {
        return KILN_DB_CONFIG;
    }
    conn->result_format = format;
    conn->ready_hint = chunk;
    return KILN_DB_OK;
}

int kiln_db_fail(
    kiln_db_conn *conn, int code, int vendor, const char *sqlstate, const char *message) {
    const kiln_db_limits *limits = kiln_db_limits_get();
    size_t cap;
    size_t n = 0;
    char *copy;
    if (!conn) {
        return KILN_DB_ERR;
    }
    conn->err = code;
    conn->vendor_errno = vendor;
    memset(conn->sqlstate, 0, sizeof conn->sqlstate);
    if (sqlstate) {
        size_t i;
        for (i = 0; i < 5 && sqlstate[i]; i++) {
            conn->sqlstate[i] = sqlstate[i];
        }
    }
    if (message) {
        n = strlen(message);
    }
    cap = limits ? limits->max_error_bytes : 4096u;
    if (n > cap) {
        n = cap;
    }
    copy = malloc(n + 1);
    if (!copy) {
        free(conn->error);
        conn->error = NULL;
        return code;
    }
    if (n) {
        memcpy(copy, message, n);
    }
    copy[n] = 0;
    free(conn->error);
    conn->error = copy;
    return code;
}

int kiln_db_take_error_impl(uint64_t handle, uint64_t scope, uint64_t thread_id, char *buf,
    size_t cap, int *vendor, char sqlstate[6]) {
    kiln_db_conn *conn;
    int err = KILN_DB_OK;
    size_t n;
    conn = kiln_db_conn_get(handle, scope, thread_id, &err);
    if (!conn) {
        return err;
    }
    if (vendor) {
        *vendor = conn->vendor_errno;
    }
    if (sqlstate) {
        memcpy(sqlstate, conn->sqlstate, 6);
    }
    if (!buf || cap == 0) {
        return conn->err;
    }
    n = conn->error ? strlen(conn->error) : 0;
    if (n >= cap) {
        n = cap - 1;
    }
    if (n && conn->error) {
        memcpy(buf, conn->error, n);
    }
    buf[n] = 0;
    return conn->err;
}

const char *kiln_db_error_text_impl(uint64_t handle, uint64_t scope, uint64_t thread_id) {
    static __thread char empty[1];
    kiln_db_conn *conn;
    int err = KILN_DB_OK;
    conn = kiln_db_conn_get(handle, scope, thread_id, &err);
    if (!conn || !conn->error) {
        empty[0] = 0;
        sp_ffi_bin_len = 0;
        return empty;
    }
    sp_ffi_bin_len = (int)strlen(conn->error);
    return conn->error;
}

void kiln_db_step_out(
    int64_t *out, int out_n, int status, int fd, int ready_bits, int64_t timeout_ms, int err) {
    if (!out || out_n < 8) {
        return;
    }
    out[0] = status;
    out[1] = fd;
    out[2] = ready_bits;
    out[3] = timeout_ms;
    out[4] = err;
    out[5] = 0;
    out[6] = 0;
    out[7] = 0;
}

static void fill_tail(int64_t *out, int out_n, const kiln_db_conn *conn) {
    uint64_t packed = 0;
    if (!out || out_n < 8 || !conn) {
        return;
    }
    memcpy(&packed, conn->sqlstate, 5);
    out[5] = (int64_t)packed;
    out[6] = conn->vendor_errno;
    out[7] = conn->rows_affected;
}

static int step_reject(kiln_db_conn *conn, int64_t *out, int out_n, int code, const char *message) {
    kiln_db_fail(conn, code, 0, NULL, message);
    kiln_db_step_out(out, out_n, KILN_DB_STEP_ERR, conn->fd, 0, 0, code);
    fill_tail(out, out_n, conn);
    return code;
}

static int step_close(
    uint64_t handle, uint64_t scope, uint64_t thread_id, int64_t *out, int out_n) {
    kiln_db_conn *conn;
    kiln_db_release_fn release;
    void *taken = NULL;
    int err = kiln_db_slot_take_conn_idle(handle, scope, thread_id, &taken);
    if (err != KILN_DB_OK) {
        kiln_db_step_out(out, out_n, KILN_DB_STEP_ERR, -1, 0, 0, err);
        return err;
    }
    conn = taken;
    release = release_of[conn->kind];
    if (release) {
        release(conn);
    }
    kiln_db_step_out(out, out_n, KILN_DB_STEP_DONE, -1, 0, 0, KILN_DB_OK);
    conn_clear(conn);
    return KILN_DB_OK;
}

int kiln_db_step_impl(uint64_t handle, uint64_t scope, uint64_t thread_id, int op, int ready_bits,
    int64_t deadline_ms, int64_t *out, int out_n) {
    kiln_db_conn *conn;
    int err = KILN_DB_OK;
    int status;
    int resumed;
    kiln_db_step_fn fn;
    if (op == KILN_DB_OP_CLOSE) {
        return step_close(handle, scope, thread_id, out, out_n);
    }
    conn = kiln_db_conn_get(handle, scope, thread_id, &err);
    if (!conn) {
        kiln_db_step_out(out, out_n, KILN_DB_STEP_ERR, -1, 0, 0, err);
        return err;
    }
    if (conn->active_op && !pthread_equal(conn->owner, pthread_self())) {
        conn->broken = 1;
        return step_reject(
            conn, out, out_n, KILN_DB_OWNERSHIP, "active operation resumed from another OS thread");
    }
    if (conn->active_op && op != conn->active_op && op != KILN_DB_OP_CANCEL) {
        return step_reject(conn, out, out_n, KILN_DB_BUSY, "operation in progress");
    }
    if (conn->broken) {
        return step_reject(conn, out, out_n, KILN_DB_CONN, "connection broken");
    }
    fn = step_of[conn->kind];
    if (!fn) {
        return step_reject(conn, out, out_n, KILN_DB_UNSUPPORTED, "driver not registered");
    }
    resumed = conn->active_op != 0;
    conn->op = op;
    conn->deadline_ms = deadline_ms;
    conn->err = KILN_DB_OK;
    status = fn(conn, ready_bits, deadline_ms);
    if (status != KILN_DB_STEP_DONE && status != KILN_DB_STEP_WAIT && status != KILN_DB_STEP_ERR) {
        status = KILN_DB_STEP_ERR;
        conn->err = KILN_DB_ERR;
    }
    if (status == KILN_DB_STEP_WAIT) {
        if (!resumed) {
            conn->active_op = op;
            conn->owner = pthread_self();
        }
    } else if (!(op == KILN_DB_OP_CANCEL && status == KILN_DB_STEP_ERR && resumed)) {
        conn->active_op = 0;
    }
    kiln_db_step_out(out, out_n, status, conn->fd, conn->wait_kind, conn->wait_ms,
        conn->err ? conn->err : KILN_DB_OK);
    fill_tail(out, out_n, conn);
    return status == KILN_DB_STEP_ERR ? conn->err : KILN_DB_OK;
}

int kiln_db_bind_str_impl(uint64_t handle, uint64_t scope, uint64_t thread_id, uint32_t index,
    const char *data, long n, int is_null, int format) {
    kiln_db_conn *conn;
    int err = KILN_DB_OK;
    conn = kiln_db_conn_get(handle, scope, thread_id, &err);
    if (!conn) {
        return err;
    }
    if (conn->active_op) {
        return KILN_DB_BUSY;
    }
    if (conn->kind == KILN_DB_KIND_PG) {
        return kiln_db_pg_bind_str(conn, index, data, n, is_null, format);
    }
    if (conn->kind == KILN_DB_KIND_MY) {
        return kiln_db_my_bind_str(conn, index, data, n, is_null, format);
    }
    return KILN_DB_CONFIG;
}

int kiln_db_result_types_impl(
    uint64_t handle, uint64_t scope, uint64_t thread_id, int64_t *out, int n) {
    kiln_db_conn *conn;
    int err = KILN_DB_OK;
    conn = kiln_db_conn_get(handle, scope, thread_id, &err);
    if (!conn) {
        return err;
    }
    if (conn->kind == KILN_DB_KIND_PG) {
        return kiln_db_pg_result_types(conn, out, n);
    }
    if (conn->kind == KILN_DB_KIND_MY) {
        return kiln_db_my_result_types(conn, out, n);
    }
    return KILN_DB_CONFIG;
}

const char *kiln_db_result_row_impl(
    uint64_t handle, uint64_t scope, uint64_t thread_id, uint32_t row, int64_t *lens, int n) {
    static __thread char empty[1];
    kiln_db_conn *conn;
    int err = KILN_DB_OK;
    conn = kiln_db_conn_get(handle, scope, thread_id, &err);
    empty[0] = 0;
    if (conn && conn->kind == KILN_DB_KIND_PG) {
        return kiln_db_pg_result_row(conn, row, lens, n);
    }
    if (conn && conn->kind == KILN_DB_KIND_MY) {
        return kiln_db_my_result_row(conn, row, lens, n);
    }
    sp_ffi_bin_len = 0;
    return empty;
}

int kiln_db_conn_broken_impl(uint64_t handle, uint64_t scope, uint64_t thread_id) {
    kiln_db_conn *conn;
    int err = KILN_DB_OK;
    conn = kiln_db_conn_get(handle, scope, thread_id, &err);
    if (!conn) {
        return 1;
    }
    return conn->broken || conn->active_op ? 1 : 0;
}

int64_t kiln_db_os_thread_token(void) {
    pthread_t self = pthread_self();
    uint64_t token = 0;
    memcpy(&token, &self, sizeof(pthread_t) < sizeof token ? sizeof(pthread_t) : sizeof token);
    return (int64_t)token;
}

int kiln_db_result_meta_impl(
    uint64_t handle, uint64_t scope, uint64_t thread_id, int64_t *out, int n) {
    kiln_db_conn *conn;
    int err = KILN_DB_OK;
    conn = kiln_db_conn_get(handle, scope, thread_id, &err);
    if (!conn) {
        return err;
    }
    if (conn->kind == KILN_DB_KIND_PG) {
        return kiln_db_pg_result_meta(conn, out, n);
    }
    if (conn->kind == KILN_DB_KIND_MY) {
        return kiln_db_my_result_meta(conn, out, n);
    }
    return KILN_DB_CONFIG;
}

const char *kiln_db_result_bytes_impl(uint64_t handle, uint64_t scope, uint64_t thread_id,
    uint32_t row, uint32_t col, int64_t *meta, int meta_n) {
    kiln_db_conn *conn;
    int err = KILN_DB_OK;
    static __thread char empty[1];
    conn = kiln_db_conn_get(handle, scope, thread_id, &err);
    if (!conn) {
        empty[0] = 0;
        sp_ffi_bin_len = 0;
        if (meta && meta_n > 0) {
            meta[0] = 1;
        }
        return empty;
    }
    if (conn->kind == KILN_DB_KIND_PG) {
        return kiln_db_pg_result_bytes(conn, row, col, meta, meta_n);
    }
    if (conn->kind == KILN_DB_KIND_MY) {
        return kiln_db_my_result_bytes(conn, row, col, meta, meta_n);
    }
    empty[0] = 0;
    sp_ffi_bin_len = 0;
    return empty;
}

int64_t kiln_db_peer_id_impl(uint64_t handle, uint64_t scope, uint64_t thread_id) {
    kiln_db_conn *conn;
    int err = KILN_DB_OK;
    conn = kiln_db_conn_get(handle, scope, thread_id, &err);
    if (!conn) {
        return -1;
    }
    return (int64_t)conn->mysql_thread;
}

typedef struct {
    char *bytes;
    size_t cap;
} kiln_db_thread_data;

static pthread_key_t kiln_db_copy_key;
static pthread_once_t kiln_db_copy_once = PTHREAD_ONCE_INIT;

static void kiln_db_thread_free(void *value) {
    kiln_db_thread_data *data = value;
    if (data) {
        free(data->bytes);
        free(data);
    }
}

static void kiln_db_copy_key_init(void) {
    pthread_key_create(&kiln_db_copy_key, kiln_db_thread_free);
}

static kiln_db_thread_data *kiln_db_thread_get(void) {
    kiln_db_thread_data *data;
    if (pthread_once(&kiln_db_copy_once, kiln_db_copy_key_init)) {
        return NULL;
    }
    data = pthread_getspecific(kiln_db_copy_key);
    if (!data) {
        data = calloc(1, sizeof *data);
        if (!data) {
            return NULL;
        }
        if (pthread_setspecific(kiln_db_copy_key, data)) {
            free(data);
            return NULL;
        }
    }
    return data;
}

char *kiln_db_thread_room(size_t need) {
    kiln_db_thread_data *data = kiln_db_thread_get();
    size_t cap;
    char *bytes;
    if (!data || need == 0 || need > (size_t)INT_MAX + 1u) {
        return NULL;
    }
    if (data->cap < need) {
        cap = data->cap ? data->cap : 256;
        while (cap < need) {
            if (cap > SIZE_MAX / 2) {
                cap = need;
                break;
            }
            cap *= 2;
        }
        bytes = realloc(data->bytes, cap);
        if (!bytes) {
            return NULL;
        }
        data->bytes = bytes;
        data->cap = cap;
    }
    return data->bytes;
}

int kiln_db_format_i64(int64_t value, char *out, size_t cap) {
    char rev[24];
    uint64_t mag = value < 0 ? (uint64_t)0 - (uint64_t)value : (uint64_t)value;
    int n = 0;
    int at = 0;
    do {
        rev[n++] = (char)('0' + (int)(mag % 10u));
        mag /= 10u;
    } while (mag != 0);
    if (!out || (size_t)n + 2u > cap) {
        return -1;
    }
    if (value < 0) {
        out[at++] = '-';
    }
    while (n > 0) {
        out[at++] = rev[--n];
    }
    out[at] = 0;
    return at;
}

static int kiln_db_put_word(const char *word, char *out, size_t cap) {
    size_t n = strlen(word);
    if (!out || n + 1u > cap) {
        return -1;
    }
    memcpy(out, word, n + 1u);
    return (int)n;
}

int kiln_db_format_f64(double value, char *out, size_t cap) {
    int digits;
    if (value != value) {
        return kiln_db_put_word("NaN", out, cap);
    }
    if (value > DBL_MAX) {
        return kiln_db_put_word("Infinity", out, cap);
    }
    if (value < -DBL_MAX) {
        return kiln_db_put_word("-Infinity", out, cap);
    }
    for (digits = 15; digits <= 17; digits++) {
        int n = out ? snprintf(out, cap, "%.*g", digits, value) : -1;
        if (n <= 0 || (size_t)n >= cap) {
            return -1;
        }
        if (digits == 17 || strtod(out, NULL) == value) {
            return n;
        }
    }
    return -1;
}

static const char *kiln_db_thread_bytes(void) {
    kiln_db_thread_data *data = kiln_db_thread_get();
    return data ? data->bytes : NULL;
}

static const char *kiln_db_thread_copy(const char *src, size_t len, int *ok) {
    char *bytes;
    *ok = 0;
    if (len == SIZE_MAX || len > INT_MAX) {
        return NULL;
    }
    if (len && src && src == kiln_db_thread_bytes()) {
        *ok = 1;
        return src;
    }
    bytes = kiln_db_thread_room(len + 1);
    if (!bytes) {
        return NULL;
    }
    if (len) {
        if (!src) {
            return NULL;
        }
        memcpy(bytes, src, len);
    }
    bytes[len] = 0;
    *ok = 1;
    return bytes;
}

static int kiln_db_pin_conn(uint64_t handle, uint64_t scope, uint64_t thread_id) {
    int err = KILN_DB_OK;
    kiln_db_conn *conn = kiln_db_slot_acquire(handle, KILN_DB_SLOT_CONN, scope, thread_id, &err);
    if (!conn) {
        return err;
    }
    kiln_db_held_handle = handle;
    kiln_db_held_scope = scope;
    kiln_db_held_thread = thread_id;
    kiln_db_held_conn = conn;
    return KILN_DB_OK;
}

static void kiln_db_unpin_conn(uint64_t handle, uint64_t scope, uint64_t thread_id) {
    (void)scope;
    (void)thread_id;
    if (kiln_db_held_handle == handle) {
        kiln_db_held_conn = NULL;
        kiln_db_held_handle = 0;
    }
    kiln_db_slot_release(handle, KILN_DB_SLOT_CONN);
}

const char *kiln_db_result_rows(uint64_t handle, uint64_t scope, uint64_t thread_id,
    int64_t first_row, int64_t max_rows, int64_t max_bytes, int64_t *lens, int lens_cap,
    int64_t *meta, int meta_n) {
    static const char empty[] = "";
    const char *out = empty;
    kiln_db_conn *conn;
    sp_ffi_bin_len = 0;
    if (!meta || meta_n < 3) {
        return empty;
    }
    meta[0] = -2;
    meta[1] = 0;
    meta[2] = 0;
    if (!lens || lens_cap <= 0 || first_row < 0 || first_row > (int64_t)UINT32_MAX ||
        max_rows <= 0 || max_bytes <= 0) {
        return empty;
    }
    if (kiln_db_pin_conn(handle, scope, thread_id) != KILN_DB_OK) {
        return empty;
    }
    conn = kiln_db_held_conn;
    if (max_rows > (int64_t)UINT32_MAX) {
        max_rows = (int64_t)UINT32_MAX;
    }
    if (conn->kind == KILN_DB_KIND_PG) {
        out = kiln_db_pg_result_rows(conn, (uint32_t)first_row, (uint32_t)max_rows,
            (size_t)max_bytes, lens, lens_cap, meta);
    } else if (conn->kind == KILN_DB_KIND_MY) {
        out = kiln_db_my_result_rows(conn, (uint32_t)first_row, (uint32_t)max_rows,
            (size_t)max_bytes, lens, lens_cap, meta);
    }
    kiln_db_unpin_conn(handle, scope, thread_id);
    return out;
}

const char *kiln_db_result_rows_typed(uint64_t handle, uint64_t scope, uint64_t thread_id,
    int64_t first_row, int64_t max_rows, int64_t max_bytes, int64_t *lens, int lens_cap,
    int64_t *nums, double *floats, int64_t *meta, int meta_n) {
    static const char empty[] = "";
    const char *out = empty;
    kiln_db_conn *conn;
    sp_ffi_bin_len = 0;
    if (!meta || meta_n < 3) {
        return empty;
    }
    meta[0] = -2;
    meta[1] = 0;
    meta[2] = 0;
    if (!lens || !nums || !floats || lens_cap <= 0 || first_row < 0 ||
        first_row > (int64_t)UINT32_MAX || max_rows <= 0 || max_bytes <= 0) {
        return empty;
    }
    if (kiln_db_pin_conn(handle, scope, thread_id) != KILN_DB_OK) {
        return empty;
    }
    conn = kiln_db_held_conn;
    if (max_rows > (int64_t)UINT32_MAX) {
        max_rows = (int64_t)UINT32_MAX;
    }
    if (conn->kind == KILN_DB_KIND_PG) {
        out = kiln_db_pg_result_rows_typed(conn, (uint32_t)first_row, (uint32_t)max_rows,
            (size_t)max_bytes, lens, lens_cap, nums, floats, meta);
    } else if (conn->kind == KILN_DB_KIND_MY) {
        out = kiln_db_my_result_rows_typed(conn, (uint32_t)first_row, (uint32_t)max_rows,
            (size_t)max_bytes, lens, lens_cap, nums, floats, meta);
    }
    kiln_db_unpin_conn(handle, scope, thread_id);
    return out;
}

int kiln_db_conn_set(uint64_t handle, uint64_t scope, uint64_t thread_id, const char *host,
    size_t host_len, int port, const char *user, size_t user_len, const char *pass, size_t pass_len,
    const char *database, size_t database_len, int ssl_mode, const char *ca, size_t ca_len,
    int allow_insecure, const char *tls_name, size_t tls_name_len) {
    int pin = kiln_db_pin_conn(handle, scope, thread_id);
    int value;
    if (pin != KILN_DB_OK) {
        return pin;
    }
    value = kiln_db_conn_set_impl(handle, scope, thread_id, host, host_len, port, user, user_len,
        pass, pass_len, database, database_len, ssl_mode, ca, ca_len, allow_insecure, tls_name,
        tls_name_len);
    kiln_db_unpin_conn(handle, scope, thread_id);
    return value;
}

int kiln_db_set_sql(
    uint64_t handle, uint64_t scope, uint64_t thread_id, const char *sql, size_t sql_len) {
    int pin = kiln_db_pin_conn(handle, scope, thread_id);
    int value;
    if (pin != KILN_DB_OK) {
        return pin;
    }
    value = kiln_db_set_sql_impl(handle, scope, thread_id, sql, sql_len);
    kiln_db_unpin_conn(handle, scope, thread_id);
    return value;
}

static int kiln_db_set_copy_impl(
    uint64_t handle, uint64_t scope, uint64_t thread_id, const char *data, long len) {
    const kiln_db_limits *limits = kiln_db_limits_get();
    kiln_db_conn *conn;
    int err = KILN_DB_OK;
    conn = kiln_db_conn_get(handle, scope, thread_id, &err);
    if (!conn) {
        return err;
    }
    if (conn->active_op) {
        return KILN_DB_BUSY;
    }
    if (conn->kind != KILN_DB_KIND_PG) {
        return KILN_DB_UNSUPPORTED;
    }
    if (!limits) {
        return KILN_DB_CONFIG;
    }
    if (len < 0 || (len > 0 && !data)) {
        return KILN_DB_ERR;
    }
    if ((uint64_t)len > limits->max_payload_bytes) {
        return KILN_DB_CAPACITY;
    }
    return kiln_db_pg_set_copy(conn, data, len);
}

int kiln_db_set_copy(
    uint64_t handle, uint64_t scope, uint64_t thread_id, const char *data, long len) {
    int pin = kiln_db_pin_conn(handle, scope, thread_id);
    int value;
    if (pin != KILN_DB_OK) {
        return pin;
    }
    value = kiln_db_set_copy_impl(handle, scope, thread_id, data, len);
    kiln_db_unpin_conn(handle, scope, thread_id);
    return value;
}

int kiln_db_set_format(uint64_t handle, uint64_t scope, uint64_t thread_id, int format, int chunk) {
    int pin = kiln_db_pin_conn(handle, scope, thread_id);
    int value;
    if (pin != KILN_DB_OK) {
        return pin;
    }
    value = kiln_db_set_format_impl(handle, scope, thread_id, format, chunk);
    kiln_db_unpin_conn(handle, scope, thread_id);
    return value;
}

static int kiln_db_set_stmt_cache_impl(
    uint64_t handle, uint64_t scope, uint64_t thread_id, int capacity) {
    kiln_db_conn *conn;
    int err = KILN_DB_OK;
    conn = kiln_db_conn_get(handle, scope, thread_id, &err);
    if (!conn) {
        return err;
    }
    if (conn->active_op) {
        return KILN_DB_BUSY;
    }
    if (capacity < 0 || capacity > 256) {
        return KILN_DB_CONFIG;
    }
    conn->stmt_cache = capacity;
    return KILN_DB_OK;
}

int kiln_db_set_stmt_cache(uint64_t handle, uint64_t scope, uint64_t thread_id, int capacity) {
    int pin = kiln_db_pin_conn(handle, scope, thread_id);
    int value;
    if (pin != KILN_DB_OK) {
        return pin;
    }
    value = kiln_db_set_stmt_cache_impl(handle, scope, thread_id, capacity);
    kiln_db_unpin_conn(handle, scope, thread_id);
    return value;
}

int kiln_db_take_error(uint64_t handle, uint64_t scope, uint64_t thread_id, char *buf, size_t cap,
    int *vendor, char sqlstate[6]) {
    int pin = kiln_db_pin_conn(handle, scope, thread_id);
    int value;
    if (pin != KILN_DB_OK) {
        return pin;
    }
    value = kiln_db_take_error_impl(handle, scope, thread_id, buf, cap, vendor, sqlstate);
    kiln_db_unpin_conn(handle, scope, thread_id);
    return value;
}

int kiln_db_bind_str(uint64_t handle, uint64_t scope, uint64_t thread_id, uint32_t index,
    const char *data, long n, int is_null, int format) {
    int pin = kiln_db_pin_conn(handle, scope, thread_id);
    int value;
    if (pin != KILN_DB_OK) {
        return pin;
    }
    value = kiln_db_bind_str_impl(handle, scope, thread_id, index, data, n, is_null, format);
    kiln_db_unpin_conn(handle, scope, thread_id);
    return value;
}

int kiln_db_result_types(uint64_t handle, uint64_t scope, uint64_t thread_id, int64_t *out, int n) {
    int pin = kiln_db_pin_conn(handle, scope, thread_id);
    int value;
    if (pin != KILN_DB_OK) {
        return pin;
    }
    value = kiln_db_result_types_impl(handle, scope, thread_id, out, n);
    kiln_db_unpin_conn(handle, scope, thread_id);
    return value;
}

int kiln_db_result_meta(uint64_t handle, uint64_t scope, uint64_t thread_id, int64_t *out, int n) {
    int pin = kiln_db_pin_conn(handle, scope, thread_id);
    int value;
    if (pin != KILN_DB_OK) {
        return pin;
    }
    value = kiln_db_result_meta_impl(handle, scope, thread_id, out, n);
    kiln_db_unpin_conn(handle, scope, thread_id);
    return value;
}

int kiln_db_conn_broken(uint64_t handle, uint64_t scope, uint64_t thread_id) {
    int pin = kiln_db_pin_conn(handle, scope, thread_id);
    int value;
    if (pin != KILN_DB_OK) {
        return pin;
    }
    value = kiln_db_conn_broken_impl(handle, scope, thread_id);
    kiln_db_unpin_conn(handle, scope, thread_id);
    return value;
}

int64_t kiln_db_peer_id(uint64_t handle, uint64_t scope, uint64_t thread_id) {
    int pin = kiln_db_pin_conn(handle, scope, thread_id);
    int64_t value;
    if (pin != KILN_DB_OK) {
        return -1;
    }
    value = kiln_db_peer_id_impl(handle, scope, thread_id);
    kiln_db_unpin_conn(handle, scope, thread_id);
    return value;
}

int kiln_db_step(uint64_t handle, uint64_t scope, uint64_t thread_id, int op, int ready_bits,
    int64_t deadline_ms, int64_t *out, int out_n) {
    int pin;
    int rc;
    if (op == KILN_DB_OP_CLOSE) {
        return kiln_db_step_impl(handle, scope, thread_id, op, ready_bits, deadline_ms, out, out_n);
    }
    pin = kiln_db_pin_conn(handle, scope, thread_id);
    if (pin != KILN_DB_OK) {
        kiln_db_step_out(out, out_n, KILN_DB_STEP_ERR, -1, 0, 0, pin);
        return pin;
    }
    rc = kiln_db_step_impl(handle, scope, thread_id, op, ready_bits, deadline_ms, out, out_n);
    kiln_db_unpin_conn(handle, scope, thread_id);
    return rc;
}

const char *kiln_db_result_row(
    uint64_t handle, uint64_t scope, uint64_t thread_id, uint32_t row, int64_t *lens, int n) {
    static const char empty[] = "";
    int pin = kiln_db_pin_conn(handle, scope, thread_id);
    const char *ptr;
    const char *copy;
    int ok = 0;
    int nbytes;
    if (pin != KILN_DB_OK) {
        if (lens && n > 0) {
            lens[0] = -2;
        }
        sp_ffi_bin_len = 0;
        return empty;
    }
    ptr = kiln_db_result_row_impl(handle, scope, thread_id, row, lens, n);
    nbytes = sp_ffi_bin_len;
    copy = nbytes >= 0 ? kiln_db_thread_copy(ptr, (size_t)nbytes, &ok) : NULL;
    kiln_db_unpin_conn(handle, scope, thread_id);
    if (!ok) {
        if (lens && n > 0) {
            lens[0] = -2;
        }
        sp_ffi_bin_len = 0;
        return empty;
    }
    sp_ffi_bin_len = nbytes;
    return copy;
}

const char *kiln_db_result_bytes(uint64_t handle, uint64_t scope, uint64_t thread_id, uint32_t row,
    uint32_t col, int64_t *meta, int meta_n) {
    static const char empty[] = "";
    int pin = kiln_db_pin_conn(handle, scope, thread_id);
    const char *ptr;
    const char *copy;
    int ok = 0;
    int nbytes;
    if (pin != KILN_DB_OK) {
        if (meta && meta_n > 0) {
            meta[0] = -2;
        }
        sp_ffi_bin_len = 0;
        return empty;
    }
    ptr = kiln_db_result_bytes_impl(handle, scope, thread_id, row, col, meta, meta_n);
    nbytes = sp_ffi_bin_len;
    copy = nbytes >= 0 ? kiln_db_thread_copy(ptr, (size_t)nbytes, &ok) : NULL;
    kiln_db_unpin_conn(handle, scope, thread_id);
    if (!ok) {
        if (meta && meta_n > 0) {
            meta[0] = -2;
        }
        sp_ffi_bin_len = 0;
        return empty;
    }
    sp_ffi_bin_len = nbytes;
    return copy;
}

const char *kiln_db_error_text(uint64_t handle, uint64_t scope, uint64_t thread_id) {
    static const char empty[] = "";
    int pin = kiln_db_pin_conn(handle, scope, thread_id);
    const char *ptr;
    const char *copy;
    int ok = 0;
    int nbytes;
    if (pin != KILN_DB_OK) {
        sp_ffi_bin_len = 0;
        return empty;
    }
    ptr = kiln_db_error_text_impl(handle, scope, thread_id);
    nbytes = sp_ffi_bin_len;
    copy = nbytes >= 0 ? kiln_db_thread_copy(ptr, (size_t)nbytes, &ok) : NULL;
    kiln_db_unpin_conn(handle, scope, thread_id);
    if (!ok) {
        sp_ffi_bin_len = 0;
        return empty;
    }
    sp_ffi_bin_len = nbytes;
    return copy;
}

static int kiln_db_hostaddr_valid(const char *list, size_t n) {
    unsigned char ip[16];
    char one[INET6_ADDRSTRLEN];
    size_t start = 0;
    size_t i;
    int count = 0;
    for (i = 0; i <= n; i++) {
        if (i == n || list[i] == ',') {
            size_t len = i - start;
            if (len == 0 || len >= sizeof one || ++count > KILN_DB_HOSTADDR_MAX) {
                return 0;
            }
            memcpy(one, list + start, len);
            one[len] = 0;
            if (inet_pton(AF_INET, one, ip) != 1 && inet_pton(AF_INET6, one, ip) != 1) {
                return 0;
            }
            start = i + 1;
        }
    }
    return count;
}

int kiln_db_conn_set_hostaddr(
    uint64_t handle, uint64_t scope, uint64_t thread_id, const char *addr, long n) {
    int rc = kiln_db_pin_conn(handle, scope, thread_id);
    kiln_db_conn *conn;
    int err = KILN_DB_OK;
    char *copy;
    if (rc != KILN_DB_OK) {
        return rc;
    }
    conn = kiln_db_conn_get(handle, scope, thread_id, &err);
    if (conn && conn->active_op) {
        rc = KILN_DB_BUSY;
    } else if (!addr || n <= 0 || n >= KILN_DB_HOSTADDR_CAP || !conn ||
               !kiln_db_hostaddr_valid(addr, (size_t)n)) {
        rc = KILN_DB_CONFIG;
    } else {
        copy = malloc((size_t)n + 1);
        if (!copy) {
            rc = KILN_DB_CAPACITY;
        } else {
            memcpy(copy, addr, (size_t)n);
            copy[n] = 0;
            free(conn->hostaddr);
            conn->hostaddr = copy;
            rc = KILN_DB_OK;
        }
    }
    kiln_db_unpin_conn(handle, scope, thread_id);
    return rc;
}
