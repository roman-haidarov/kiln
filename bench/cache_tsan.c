#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../ext/kiln_cache.h"

__thread int sp_ffi_bin_len;

#define TS_THREADS 8
#define TS_KEYS    1024
#define TS_OPS     60000
#define TS_ENTRIES 512
#define TS_BYTES   (64 * 1024)
#define TS_VALUE   512

typedef struct {
    long handle;
    unsigned seed;
    long failures;
} ts_worker;

static unsigned ts_next(unsigned *state) {
    *state = (*state * 1103515245u) + 12345u;
    return *state >> 8;
}

static int ts_key(char *out, unsigned index) {
    return snprintf(out, 32, "key-%u", index);
}

static void *ts_run(void *arg) {
    ts_worker *worker = arg;
    char key[32];
    char value[TS_VALUE + 64];
    for (long op = 0; op < TS_OPS; op++) {
        unsigned roll = ts_next(&worker->seed);
        int klen = ts_key(key, roll % TS_KEYS);
        unsigned kind = (roll >> 12) % 100;
        if (kind < 45) {
            int vlen = snprintf(value, sizeof(value), "%s|%ld|", key, op);
            int pad = (int)(ts_next(&worker->seed) % (TS_VALUE + 40));
            if (vlen + pad > (int)sizeof(value)) {
                pad = (int)sizeof(value) - vlen;
            }
            memset(value + vlen, 'p', (size_t)pad);
            long ttl = (kind % 7 == 0) ? 1 : 0;
            if (kiln_cache_set(worker->handle, key, klen, value, vlen + pad, ttl) < 0) {
                worker->failures++;
            }
        } else if (kind < 90) {
            const char *got = kiln_cache_get(worker->handle, key, klen);
            if (kiln_cache_found() == 1) {
                size_t prefix = strlen(key);
                if ((size_t)sp_ffi_bin_len <= prefix || memcmp(got, key, prefix) != 0 ||
                    got[prefix] != '|') {
                    worker->failures++;
                }
            } else if (kiln_cache_found() != 0) {
                worker->failures++;
            }
        } else if (kind < 97) {
            if (kiln_cache_delete(worker->handle, key, klen) < 0) {
                worker->failures++;
            }
        } else if (kind < 99) {
            kiln_cache_sweep(worker->handle, 32);
        } else if ((roll & 0xff) == 0) {
            kiln_cache_clear(worker->handle);
        }
    }
    return NULL;
}

int main(void) {
    long handle = kiln_cache_new(4, TS_ENTRIES, TS_BYTES, TS_VALUE);
    if (handle < 0) {
        fprintf(stderr, "cache create failed: %ld\n", handle);
        return 1;
    }
    pthread_t threads[TS_THREADS];
    ts_worker workers[TS_THREADS];
    for (int i = 0; i < TS_THREADS; i++) {
        workers[i] = (ts_worker){handle, (unsigned)(i * 7919 + 17), 0};
        pthread_create(&threads[i], NULL, ts_run, &workers[i]);
    }
    long failures = 0;
    for (int i = 0; i < TS_THREADS; i++) {
        pthread_join(threads[i], NULL);
        failures += workers[i].failures;
    }
    int64_t stats[KILN_CACHE_STATS];
    if (kiln_cache_stats(handle, stats, KILN_CACHE_STATS) != KILN_CACHE_STATS) {
        fprintf(stderr, "stats failed\n");
        return 1;
    }
    if (stats[0] > TS_ENTRIES || stats[1] > TS_BYTES) {
        fprintf(stderr, "limits exceeded: entries=%lld bytes=%lld\n", (long long)stats[0],
            (long long)stats[1]);
        return 1;
    }
    if (failures) {
        fprintf(stderr, "cache returned a wrong value or status %ld times\n", failures);
        return 1;
    }
    if (kiln_cache_free(handle) != 0) {
        fprintf(stderr, "free failed\n");
        return 1;
    }
    printf("cache TSan: %d threads, %d ops each, entries=%lld bytes=%lld hits=%lld misses=%lld "
           "evictions=%lld expirations=%lld refusals=%lld passed\n",
        TS_THREADS, TS_OPS, (long long)stats[0], (long long)stats[1], (long long)stats[2],
        (long long)stats[3], (long long)stats[4], (long long)stats[5], (long long)stats[6]);
    return 0;
}
