#include "kiln_db.h"

#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#ifdef SP_THREADS
__thread int sp_ffi_bin_len;
#else
int sp_ffi_bin_len;
#endif

static int fake_calls;
static int fake_wait;

static int fake_step(kiln_db_conn *conn, int ready_bits, int64_t deadline_ms) {
    (void)ready_bits;
    (void)deadline_ms;
    fake_calls++;
    conn->fd = -1;
    conn->wait_kind = KILN_DB_READY_TIMEOUT;
    conn->wait_ms = 1;
    return fake_wait ? KILN_DB_STEP_WAIT : KILN_DB_STEP_DONE;
}

static void fake_release(kiln_db_conn *conn) {
    (void)conn;
}

typedef struct {
    uint64_t handle;
    int op;
    int64_t out[8];
    int rc;
} step_job;

static void *step_other(void *arg) {
    step_job *job = arg;
    job->rc = kiln_db_step(job->handle, 1, 1, job->op, 0, 0, job->out, 8);
    return NULL;
}

static int fail(const char *label) {
    printf("affinity-fail %s\n", label);
    return 1;
}

int main(void) {
    int64_t values[8] = {64, 1024, 4096, 67108864, 8, 64, 16, 5000};
    int64_t err = 0;
    int64_t out[8];
    uint64_t handle;
    pthread_t other;
    step_job job;
    int before;
    if (kiln_db_configure_values(values, 8) != KILN_DB_OK) {
        return fail("configure");
    }
    kiln_db_driver_register(KILN_DB_KIND_PG, fake_step, fake_release);
    handle = kiln_db_conn_create(KILN_DB_KIND_PG, 1, 1, &err);
    if (!handle || err != KILN_DB_OK) {
        return fail("create");
    }
    if (kiln_db_conn_set_hostaddr(handle, 1, 1, "127.0.0.2,::1,127.0.0.1", 23) != KILN_DB_OK ||
        kiln_db_conn_set_hostaddr(handle, 1, 1, "127.0.0.1,", 10) != KILN_DB_CONFIG ||
        kiln_db_conn_set_hostaddr(handle, 1, 1, "127.0.0.1,example.com", 21) != KILN_DB_CONFIG ||
        kiln_db_conn_set_hostaddr(handle, 1, 1, ",127.0.0.1", 10) != KILN_DB_CONFIG ||
        kiln_db_conn_set_hostaddr(handle, 1, 1,
            "10.0.0.1,10.0.0.2,10.0.0.3,10.0.0.4,10.0.0.5,10.0.0.6,10.0.0.7,10.0.0.8,10.0.0.9",
            80) != KILN_DB_CONFIG) {
        return fail("hostaddr-list");
    }
    printf("affinity-hostaddr-list-validated\n");
    fake_wait = 1;
    kiln_db_step(handle, 1, 1, KILN_DB_OP_EXEC, 0, 0, out, 8);
    if (out[0] != KILN_DB_STEP_WAIT) {
        return fail("wait");
    }
    before = fake_calls;
    kiln_db_step(handle, 1, 1, KILN_DB_OP_BEGIN, 0, 0, out, 8);
    if (out[0] != KILN_DB_STEP_ERR || out[4] != KILN_DB_BUSY || fake_calls != before) {
        return fail("busy");
    }
    printf("affinity-busy-rejected\n");
    if (kiln_db_set_sql(handle, 1, 1, "SELECT 2", 8) != KILN_DB_BUSY ||
        kiln_db_set_format(handle, 1, 1, 0, 0) != KILN_DB_BUSY ||
        kiln_db_conn_set_hostaddr(handle, 1, 1, "127.0.0.1", 9) != KILN_DB_BUSY ||
        kiln_db_bind_str(handle, 1, 1, 0, "x", 1, 0, 0) != KILN_DB_BUSY) {
        return fail("setup-during-op");
    }
    printf("affinity-setup-during-op-rejected\n");
    memset(&job, 0, sizeof job);
    job.handle = handle;
    job.op = KILN_DB_OP_EXEC;
    if (pthread_create(&other, NULL, step_other, &job) != 0) {
        return fail("thread");
    }
    pthread_join(other, NULL);
    if (job.out[0] != KILN_DB_STEP_ERR || job.out[4] != KILN_DB_OWNERSHIP || fake_calls != before) {
        return fail("foreign-thread");
    }
    printf("affinity-foreign-thread-rejected-before-driver\n");
    if (kiln_db_conn_broken(handle, 1, 1) != 1) {
        return fail("quarantine");
    }
    job.op = KILN_DB_OP_CLOSE;
    job.rc = -1;
    if (pthread_create(&other, NULL, step_other, &job) != 0) {
        return fail("close-thread");
    }
    pthread_join(other, NULL);
    if (job.rc != KILN_DB_BUSY) {
        return fail("foreign-close");
    }
    printf("affinity-foreign-close-rejected\n");
    fake_wait = 0;
    kiln_db_step(handle, 1, 1, KILN_DB_OP_EXEC, 0, 0, out, 8);
    if (out[0] != KILN_DB_STEP_ERR || fake_calls != before) {
        return fail("broken-reuse");
    }
    printf("affinity-broken-not-reused\n");
    if (kiln_db_step(handle, 1, 1, KILN_DB_OP_CLOSE, 0, 0, out, 8) != KILN_DB_OK) {
        return fail("close");
    }
    printf("affinity-ok\n");
    return 0;
}
