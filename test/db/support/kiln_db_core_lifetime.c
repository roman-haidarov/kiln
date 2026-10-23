#include "kiln_db.h"
#include <assert.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

__thread int sp_ffi_bin_len;
static pthread_mutex_t gate_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t gate_cv = PTHREAD_COND_INITIALIZER;
static int gate_started;
static int gate_continue;
static int row_returned;
static int conn_closed;
static uint64_t test_handle;

void kiln_db_block_free(kiln_db_block *block) {
    free(block);
}
int kiln_db_pg_load(void) {
    return KILN_DB_OK;
}
int kiln_db_my_load(void) {
    return KILN_DB_OK;
}
long kiln_db_pg_client_version(void) {
    return 170000;
}
long kiln_db_my_client_version(void) {
    return 30400;
}
int kiln_db_pg_bind_str(
    kiln_db_conn *conn, uint32_t index, const char *data, long n, int is_null, int format) {
    (void)conn;
    (void)index;
    (void)data;
    (void)n;
    (void)is_null;
    (void)format;
    return KILN_DB_OK;
}
int kiln_db_my_bind_str(
    kiln_db_conn *conn, uint32_t index, const char *data, long n, int is_null, int format) {
    return kiln_db_pg_bind_str(conn, index, data, n, is_null, format);
}
int kiln_db_pg_result_meta(kiln_db_conn *conn, int64_t *out, int n) {
    (void)conn;
    if (n > 1) {
        out[0] = 1;
        out[1] = 1;
    }
    return KILN_DB_OK;
}
int kiln_db_my_result_meta(kiln_db_conn *conn, int64_t *out, int n) {
    return kiln_db_pg_result_meta(conn, out, n);
}
int kiln_db_pg_result_types(kiln_db_conn *conn, int64_t *out, int n) {
    (void)conn;
    if (n) {
        out[0] = KILN_DB_T_TEXT;
    }
    return KILN_DB_OK;
}
int kiln_db_my_result_types(kiln_db_conn *conn, int64_t *out, int n) {
    return kiln_db_pg_result_types(conn, out, n);
}
const char *kiln_db_pg_result_row(kiln_db_conn *conn, uint32_t row, int64_t *lens, int n) {
    (void)row;
    assert(n > 0);
    pthread_mutex_lock(&gate_mu);
    gate_started = 1;
    pthread_cond_broadcast(&gate_cv);
    while (!gate_continue) {
        pthread_cond_wait(&gate_cv, &gate_mu);
    }
    pthread_mutex_unlock(&gate_mu);
    lens[0] = 4;
    sp_ffi_bin_len = 4;
    return conn->native;
}
const char *kiln_db_my_result_row(kiln_db_conn *conn, uint32_t row, int64_t *lens, int n) {
    return kiln_db_pg_result_row(conn, row, lens, n);
}
const char *kiln_db_pg_result_bytes(
    kiln_db_conn *conn, uint32_t row, uint32_t col, int64_t *meta, int n) {
    (void)row;
    (void)col;
    if (n) {
        meta[0] = 0;
    }
    sp_ffi_bin_len = 4;
    return conn->native;
}
const char *kiln_db_my_result_bytes(
    kiln_db_conn *conn, uint32_t row, uint32_t col, int64_t *meta, int n) {
    return kiln_db_pg_result_bytes(conn, row, col, meta, n);
}
static int fake_step(kiln_db_conn *conn, int ready, int64_t deadline) {
    (void)conn;
    (void)ready;
    (void)deadline;
    return KILN_DB_STEP_DONE;
}
static void fake_release(kiln_db_conn *conn) {
    free(conn->native);
    conn->native = NULL;
}
static void *reader(void *ignored) {
    int64_t lens[1] = {0};
    const char *bytes;
    (void)ignored;
    bytes = kiln_db_result_row(test_handle, 1, 1, 0, lens, 1);
    assert(lens[0] == 4);
    pthread_mutex_lock(&gate_mu);
    row_returned = 1;
    pthread_cond_broadcast(&gate_cv);
    while (!conn_closed) {
        pthread_cond_wait(&gate_cv, &gate_mu);
    }
    pthread_mutex_unlock(&gate_mu);
    assert(memcmp(bytes, "\320\201\320\266", 4) == 0);
    return NULL;
}
int main(void) {
    kiln_db_limits limits = {65536, 1024, 4096, 67108864, 8, 64, 16, 5000};
    pthread_t th;
    int64_t code = 0;
    int64_t out[8];
    kiln_db_conn *conn;
    int e;
    assert(kiln_db_configure(&limits) == KILN_DB_OK);
    kiln_db_driver_register(KILN_DB_KIND_PG, fake_step, fake_release);
    test_handle = kiln_db_conn_create(KILN_DB_KIND_PG, 1, 1, &code);
    assert(test_handle && code == KILN_DB_OK);
    conn = kiln_db_conn_get(test_handle, 1, 1, &e);
    assert(conn && e == KILN_DB_OK);
    conn->native = malloc(4);
    assert(conn->native);
    memcpy(conn->native, "\320\201\320\266", 4);
    assert(pthread_create(&th, NULL, reader, NULL) == 0);
    pthread_mutex_lock(&gate_mu);
    while (!gate_started) {
        pthread_cond_wait(&gate_cv, &gate_mu);
    }
    pthread_mutex_unlock(&gate_mu);
    assert(kiln_db_step(test_handle, 1, 1, KILN_DB_OP_CLOSE, 0, 0, out, 8) == KILN_DB_BUSY);
    pthread_mutex_lock(&gate_mu);
    gate_continue = 1;
    pthread_cond_broadcast(&gate_cv);
    while (!row_returned) {
        pthread_cond_wait(&gate_cv, &gate_mu);
    }
    pthread_mutex_unlock(&gate_mu);
    assert(kiln_db_step(test_handle, 1, 1, KILN_DB_OP_CLOSE, 0, 0, out, 8) == KILN_DB_OK);
    pthread_mutex_lock(&gate_mu);
    conn_closed = 1;
    pthread_cond_broadcast(&gate_cv);
    pthread_mutex_unlock(&gate_mu);
    assert(pthread_join(th, NULL) == 0);
    printf("ok ffi result lifetime\n");
    return 0;
}
