#define _POSIX_C_SOURCE 200809L

#include "kiln_db.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#define STRESS_HANDLES 64
#define STRESS_WORKERS 4
#define STRESS_CANARY  0x6b696c6e63616e61ull

typedef struct {
    uint64_t canary;
    uint64_t serial;
} stress_obj;

typedef struct {
    int64_t acquires;
    int64_t stale;
    int64_t busy;
    int64_t broken;
    unsigned int seed;
} stress_worker;

static uint64_t handles[STRESS_HANDLES];
static int stop_flag;
static int64_t closes;

void kiln_db_block_free(kiln_db_block *block) {
    free(block);
}

static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + ((double)ts.tv_nsec / 1e9);
}

static uint64_t open_obj(uint64_t serial) {
    stress_obj *obj = malloc(sizeof *obj);
    uint64_t handle;
    int err = KILN_DB_OK;
    if (!obj) {
        return 0;
    }
    obj->canary = STRESS_CANARY;
    obj->serial = serial;
    handle = kiln_db_slot_put(KILN_DB_SLOT_CONN, obj, 1, 1, &err);
    if (!handle) {
        free(obj);
    }
    return handle;
}

static void count_rc(stress_worker *w, int rc) {
    if (rc == KILN_DB_STALE) {
        w->stale++;
    } else if (rc == KILN_DB_BUSY) {
        w->busy++;
    } else {
        w->broken++;
    }
}

static void *work(void *arg) {
    stress_worker *w = arg;
    while (!__atomic_load_n(&stop_flag, __ATOMIC_ACQUIRE)) {
        int at = rand_r(&w->seed) % STRESS_HANDLES;
        uint64_t handle = __atomic_load_n(&handles[at], __ATOMIC_ACQUIRE);
        int rc = KILN_DB_OK;
        stress_obj *obj = kiln_db_slot_acquire(handle, KILN_DB_SLOT_CONN, 1, 1, &rc);
        if (!obj) {
            count_rc(w, rc);
            continue;
        }
        if (obj->canary != STRESS_CANARY) {
            w->broken++;
        }
        w->acquires++;
        kiln_db_slot_release(handle, KILN_DB_SLOT_CONN);
    }
    return NULL;
}

static void *churn(void *arg) {
    unsigned int seed = 7;
    uint64_t serial = STRESS_HANDLES;
    (void)arg;
    while (!__atomic_load_n(&stop_flag, __ATOMIC_ACQUIRE)) {
        int at = rand_r(&seed) % STRESS_HANDLES;
        uint64_t handle = __atomic_load_n(&handles[at], __ATOMIC_ACQUIRE);
        void *taken = NULL;
        if (kiln_db_slot_take(handle, KILN_DB_SLOT_CONN, 1, 1, &taken) != KILN_DB_OK) {
            continue;
        }
        ((stress_obj *)taken)->canary = 0;
        free(taken);
        __atomic_store_n(&handles[at], open_obj(serial++), __ATOMIC_RELEASE);
        closes++;
    }
    return NULL;
}

int main(int argc, char **argv) {
    kiln_db_limits limits = {65536, 1024, 4096, 67108864, 8, 64, 16, 5000};
    stress_worker workers[STRESS_WORKERS] = {{0}};
    pthread_t threads[STRESS_WORKERS + 1];
    double seconds = argc > 1 ? atof(argv[1]) : 10.0;
    double until;
    int64_t acquires = 0;
    int64_t stale = 0;
    int64_t busy = 0;
    int64_t broken = 0;
    int i;
    if (kiln_db_configure(&limits) != KILN_DB_OK) {
        return 1;
    }
    for (i = 0; i < STRESS_HANDLES; i++) {
        handles[i] = open_obj((uint64_t)i);
    }
    for (i = 0; i < STRESS_WORKERS; i++) {
        workers[i].seed = (unsigned int)(i + 1);
        pthread_create(&threads[i], NULL, work, &workers[i]);
    }
    pthread_create(&threads[STRESS_WORKERS], NULL, churn, NULL);
    until = now_s() + seconds;
    while (now_s() < until) {
        struct timespec nap = {0, 10000000};
        nanosleep(&nap, NULL);
    }
    __atomic_store_n(&stop_flag, 1, __ATOMIC_RELEASE);
    for (i = 0; i <= STRESS_WORKERS; i++) {
        pthread_join(threads[i], NULL);
    }
    for (i = 0; i < STRESS_WORKERS; i++) {
        acquires += workers[i].acquires;
        stale += workers[i].stale;
        busy += workers[i].busy;
        broken += workers[i].broken;
    }
    printf("pin_stress acquires=%lld stale=%lld busy=%lld closes=%lld canary_failures=%lld\n",
        (long long)acquires, (long long)stale, (long long)busy, (long long)closes,
        (long long)broken);
    return broken == 0 && acquires > 0 && closes > 0 ? 0 : 1;
}
