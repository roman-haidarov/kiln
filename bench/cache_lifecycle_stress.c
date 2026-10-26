#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "../ext/kiln_cache.h"

__thread int sp_ffi_bin_len;

#define LC_THREADS 6
#define LC_ROUNDS  3000
#define LC_KEYS    32

static pthread_mutex_t lc_lock = PTHREAD_MUTEX_INITIALIZER;
static long lc_handle = -1;
static long lc_round = 0;
static atomic_int lc_stop;
static atomic_long lc_wrong;
static atomic_long lc_closed_seen;
static atomic_long lc_ops;
static atomic_long lc_busy;

static void lc_current(long *handle, long *round) {
    pthread_mutex_lock(&lc_lock);
    *handle = lc_handle;
    *round = lc_round;
    pthread_mutex_unlock(&lc_lock);
}

static int lc_value(char *out, long round) {
    return snprintf(out, 32, "r=%ld", round);
}

static void *lc_worker(void *arg) {
    unsigned state = (unsigned)(uintptr_t)arg * 2654435761u + 1u;
    char key[16];
    char want[32];
    while (!atomic_load(&lc_stop)) {
        long handle;
        long round;
        lc_current(&handle, &round);
        int wlen = lc_value(want, round);
        for (int step = 0; step < 200; step++) {
            state = state * 1103515245u + 12345u;
            int klen = snprintf(key, sizeof(key), "k%u", (state >> 8) % LC_KEYS);
            unsigned kind = (state >> 20) % 10;
            int attempt = (state >> 28) & 1;
            long status;
            if (kind < 6) {
                const char *got = attempt ? kiln_cache_get_try(handle, key, klen)
                                          : kiln_cache_get(handle, key, klen);
                status = kiln_cache_found();
                if (status == 1 &&
                    (sp_ffi_bin_len != wlen || memcmp(got, want, (size_t)wlen) != 0)) {
                    atomic_fetch_add(&lc_wrong, 1);
                }
            } else if (kind < 8) {
                status = attempt ? kiln_cache_set_try(handle, key, klen, want, wlen, 0)
                                 : kiln_cache_set(handle, key, klen, want, wlen, 0);
            } else if (kind < 9) {
                status = attempt ? kiln_cache_delete_try(handle, key, klen)
                                 : kiln_cache_delete(handle, key, klen);
            } else {
                int64_t stats[KILN_CACHE_STATS];
                status = kiln_cache_stats(handle, stats, KILN_CACHE_STATS) < 0 ? -1 : 0;
                if (status == 0) {
                    status = kiln_cache_sweep(handle, 8);
                }
            }
            atomic_fetch_add(&lc_ops, 1);
            if (status == KILN_CACHE_BUSY) {
                atomic_fetch_add(&lc_busy, 1);
                continue;
            }
            if (status < 0) {
                atomic_fetch_add(&lc_closed_seen, 1);
                break;
            }
        }
    }
    return NULL;
}

static long lc_open(long round) {
    long handle = kiln_cache_new(4, 64, 1 << 16, 256);
    if (handle < 0) {
        fprintf(stderr, "cache create failed: %ld\n", handle);
        exit(1);
    }
    char key[16];
    char value[32];
    int vlen = lc_value(value, round);
    for (int i = 0; i < LC_KEYS; i++) {
        int klen = snprintf(key, sizeof(key), "k%d", i);
        kiln_cache_set(handle, key, klen, value, vlen, 0);
    }
    return handle;
}

int main(void) {
    lc_handle = lc_open(0);
    pthread_t threads[LC_THREADS];
    for (long i = 0; i < LC_THREADS; i++) {
        if (pthread_create(&threads[i], NULL, lc_worker, (void *)(uintptr_t)(i + 1)) != 0) {
            fprintf(stderr, "cache worker could not be created\n");
            return 1;
        }
    }
    const char *configured = getenv("KILN_CACHE_STRESS_ROUNDS");
    long rounds = configured ? atol(configured) : LC_ROUNDS;
    if (rounds < 1) {
        rounds = LC_ROUNDS;
    }
    struct timespec pause = {0, 20000};
    long reused = 0;
    for (long round = 1; round <= rounds; round++) {
        nanosleep(&pause, NULL);
        long old;
        long ignored;
        lc_current(&old, &ignored);
        if (kiln_cache_free(old) != 0) {
            fprintf(stderr, "free of a live cache failed\n");
            return 1;
        }
        if (kiln_cache_free(old) != -1) {
            fprintf(stderr, "a second free of the same handle succeeded\n");
            return 1;
        }
        long fresh = lc_open(round);
        reused += (fresh & 63) == (old & 63);
        if (fresh == old) {
            fprintf(stderr, "a new cache got the handle of a closed one: %ld\n", fresh);
            return 1;
        }
        pthread_mutex_lock(&lc_lock);
        lc_handle = fresh;
        lc_round = round;
        pthread_mutex_unlock(&lc_lock);
    }
    atomic_store(&lc_stop, 1);
    for (int i = 0; i < LC_THREADS; i++) {
        if (pthread_join(threads[i], NULL) != 0) {
            fprintf(stderr, "cache worker could not be joined\n");
            return 1;
        }
    }
    kiln_cache_free(lc_handle);
    if (atomic_load(&lc_ops) == 0 || reused != rounds) {
        fprintf(stderr, "cache lifecycle stress did not exercise workers and slot reuse\n");
        return 1;
    }
    if (atomic_load(&lc_wrong)) {
        fprintf(stderr, "a stale handle read another cache's value %ld times\n",
            atomic_load(&lc_wrong));
        return 1;
    }
    if (kiln_cache_get(-1, "k", 1), kiln_cache_found() != -1) {
        fprintf(stderr, "an invalid handle was not reported\n");
        return 1;
    }
    printf("cache lifecycle stress: %d threads, %ld close/open rounds, %ld slot reuses, %ld ops, "
           "%ld busy try calls, %ld ops saw a closed cache, passed\n",
        LC_THREADS, rounds, reused, atomic_load(&lc_ops), atomic_load(&lc_busy),
        atomic_load(&lc_closed_seen));
    return 0;
}
