#include "kiln_db.h"
#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void kiln_db_block_free(kiln_db_block *block) {
    free(block);
}

typedef struct {
    uint64_t handle;
    int rc;
} close_data;

static void *try_close(void *arg) {
    close_data *data = arg;
    void *taken = NULL;
    data->rc = kiln_db_slot_take_conn_idle(data->handle, 1, 1, &taken);
    assert(taken == NULL);
    return NULL;
}

int main(void) {
    kiln_db_limits limits = {65536, 1024, 4096, 67108864, 8, 64, 16, 5000};
    kiln_db_conn *conn = calloc(1, sizeof *conn);
    uint64_t handle;
    pthread_t worker;
    close_data data;
    int err = -1;
    void *taken = NULL;
    assert(conn);
    assert(kiln_db_configure(&limits) == KILN_DB_OK);
    handle = kiln_db_slot_put(KILN_DB_SLOT_CONN, conn, 1, 1, &err);
    assert(handle && err == KILN_DB_OK);
    assert(kiln_db_slot_pin(handle, KILN_DB_SLOT_CONN, 1, 1) == KILN_DB_OK);
    assert(kiln_db_slot_pin(handle, KILN_DB_SLOT_CONN, 1, 1) == KILN_DB_BUSY);
    data.handle = handle;
    data.rc = -1;
    assert(pthread_create(&worker, NULL, try_close, &data) == 0);
    assert(pthread_join(worker, NULL) == 0);
    assert(data.rc == KILN_DB_BUSY);
    assert(kiln_db_slot_unpin(handle, KILN_DB_SLOT_CONN, 1, 1) == KILN_DB_OK);
    conn->active_op = KILN_DB_OP_EXEC;
    assert(kiln_db_slot_take_conn_idle(handle, 1, 1, &taken) == KILN_DB_BUSY);
    conn->active_op = 0;
    assert(kiln_db_slot_take_conn_idle(handle, 1, 1, &taken) == KILN_DB_OK);
    assert(taken == conn);
    free(taken);
    assert(kiln_db_slot_pin(handle, KILN_DB_SLOT_CONN, 1, 1) == KILN_DB_STALE);
    puts("ok slot lifetime");
    return 0;
}
