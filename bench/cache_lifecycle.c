#define _GNU_SOURCE
#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

__thread int sp_ffi_bin_len;

static pthread_mutex_t control = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t changed = PTHREAD_COND_INITIALIZER;
static pthread_mutex_t *paused_mutex;
static int reached, proceed, fail_key_create, fail_key_set;
static _Atomic int closed_done;

static void lc_require(int condition) {
    if (!condition) {
        abort();
    }
}

static int test_mutex_lock(pthread_mutex_t *mutex) {
    if (mutex == paused_mutex) {
        pthread_mutex_lock(&control);
        reached = 1;
        pthread_cond_broadcast(&changed);
        while (!proceed) {
            pthread_cond_wait(&changed, &control);
        }
        pthread_mutex_unlock(&control);
    }
    return pthread_mutex_lock(mutex);
}

static int test_key_create(pthread_key_t *key, void (*destructor)(void *)) {
    return fail_key_create ? EAGAIN : pthread_key_create(key, destructor);
}

static int test_key_set(pthread_key_t key, const void *value) {
    return fail_key_set ? ENOMEM : pthread_setspecific(key, value);
}

#define pthread_mutex_lock  test_mutex_lock
#define pthread_key_create  test_key_create
#define pthread_setspecific test_key_set
#include "../ext/kiln_cache.c"
#undef pthread_setspecific
#undef pthread_key_create
#undef pthread_mutex_lock

static int test_open(long handle) {
    uint32_t generation = 0;
    kc_slot *slot = kc_slot_of(handle, &generation);
    return slot && kc_open_in(atomic_load(&slot->state), generation);
}

static void *read_paused(void *argument) {
    long handle = *(long *)argument;
    const char *value = kiln_cache_get(handle, "key", 3);
    lc_require(kiln_cache_found() == 1 && sp_ffi_bin_len == 5 && memcmp(value, "value", 5) == 0);
    return NULL;
}

static void *close_paused(void *argument) {
    lc_require(kiln_cache_free(*(long *)argument) == 0);
    atomic_store(&closed_done, 1);
    return NULL;
}

static void test_close(void) {
    long handle = kiln_cache_new(1, 32, 65536, 1024);
    lc_require(handle >= 0 && kiln_cache_set(handle, "key", 3, "value", 5, 0) == 1);
    kc_slot *held = NULL;
    kc_cache *cache = kc_acquire(handle, &held);
    lc_require(cache != NULL);
    paused_mutex = &cache->shards[0].lock;
    kc_release(held);
    pthread_t reader, closer;
    lc_require(pthread_create(&reader, NULL, read_paused, &handle) == 0);
    pthread_mutex_lock(&control);
    while (!reached) {
        pthread_cond_wait(&changed, &control);
    }
    pthread_mutex_unlock(&control);
    lc_require(pthread_create(&closer, NULL, close_paused, &handle) == 0);
    int64_t deadline = kc_now_ms() + 5000;
    while (test_open(handle)) {
        lc_require(kc_now_ms() < deadline);
        sched_yield();
    }
    lc_require(atomic_load(&closed_done) == 0);
    pthread_mutex_lock(&control);
    proceed = 1;
    pthread_cond_broadcast(&changed);
    pthread_mutex_unlock(&control);
    lc_require(pthread_join(reader, NULL) == 0 && pthread_join(closer, NULL) == 0);
    paused_mutex = NULL;
    lc_require(atomic_load(&closed_done) == 1);
    long replacement = kiln_cache_new(1, 32, 65536, 1024);
    lc_require(replacement >= 0 && replacement != handle);
    lc_require(kiln_cache_set(handle, "key", 3, "bad", 3, 0) == -1);
    lc_require(kiln_cache_free(handle) == -1);
    lc_require(test_open(replacement) == 1);
    kiln_cache_get(handle, "key", 3);
    lc_require(kiln_cache_found() == -1);
    lc_require(kiln_cache_delete(handle, "key", 3) == -1);
    lc_require(kiln_cache_sweep(handle, 0) == -1 && kiln_cache_clear(handle) == -1);
    int64_t stats[KILN_CACHE_STATS] = {123};
    lc_require(kiln_cache_stats(handle, stats, KILN_CACHE_STATS) == -1 && stats[0] == 123);
    lc_require(kiln_cache_free(replacement) == 0);
    puts("cache lifecycle: paused get survives close; stale handles reject every operation");
}

static void test_limits(void) {
    lc_require(kiln_cache_new(1, LONG_MAX, LONG_MAX, 1024) == -2);
    lc_require(kiln_cache_new(3, 32, 65536, 1024) == -2);
    long handle = kiln_cache_new(8, 1024, 65536, 1024);
    lc_require(handle >= 0);
    lc_require(kiln_cache_set(handle, "huge", 4, "v", 1, LONG_MAX) == 1);
    lc_require(memcmp(kiln_cache_get(handle, "huge", 4), "v", 1) == 0);
    lc_require(kiln_cache_found() == 1);
    lc_require(kiln_cache_set(handle, "negative", 8, "v", 1, -1) == 1);
    lc_require(kiln_cache_sweep(handle, -1) == -1);
    for (int i = 0; i < 96; i++) {
        char key[32];
        int length = snprintf(key, sizeof(key), "expire:%d", i);
        lc_require(kiln_cache_set(handle, key, length, "v", 1, 1) == 1);
    }
    kc_slot *held = NULL;
    kc_cache *cache = kc_acquire(handle, &held);
    lc_require(cache != NULL);
    for (uint32_t i = 0; i < cache->shard_count; i++) {
        for (kc_entry *entry = cache->shards[i].oldest; entry; entry = entry->newer) {
            if (entry->expires && entry->expires != INT64_MAX) {
                entry->expires = 1;
            }
        }
    }
    kc_release(held);
    int64_t before[KILN_CACHE_STATS], after[KILN_CACHE_STATS];
    lc_require(kiln_cache_stats(handle, before, KILN_CACHE_STATS) == KILN_CACHE_STATS);
    lc_require(kiln_cache_sweep(handle, 0) == 0);
    lc_require(kiln_cache_stats(handle, after, KILN_CACHE_STATS) == KILN_CACHE_STATS);
    lc_require(before[0] == after[0] && before[5] == after[5]);
    long removed = 0;
    for (int i = 0; i < 1024; i++) {
        long count = kiln_cache_sweep(handle, 1);
        lc_require(count >= 0 && count <= 1);
        removed += count;
    }
    lc_require(removed == 96);
    lc_require(kiln_cache_sweep(handle, LONG_MAX) == 0);
    lc_require(kiln_cache_stats(handle, after, KILN_CACHE_STATS) == KILN_CACHE_STATS);
    lc_require(after[0] == 2 && after[5] == 96 && after[1] <= 65536);
    lc_require(kiln_cache_free(handle) == 0);
    long handles[KC_MAX_CACHES];
    for (int i = 0; i < KC_MAX_CACHES; i++) {
        handles[i] = kiln_cache_new(1, 1, 64, 0);
        lc_require(handles[i] >= 0);
    }
    lc_require(kiln_cache_new(1, 1, 64, 0) == -1);
    for (int i = 0; i < KC_MAX_CACHES; i++) {
        lc_require(kiln_cache_free(handles[i]) == 0);
    }
    puts("cache limits: TTL saturation, bounded sweep, constructor overflow, registry exhaustion "
         "passed");
}

static void test_tls_failure(int create_failure) {
    long handle = kiln_cache_new(1, 16, 65536, 4096);
    char value[2048];
    memset(value, 'x', sizeof(value));
    lc_require(handle >= 0 && kiln_cache_set(handle, "k", 1, value, 1, 0) == 1);
    if (!create_failure) {
        kiln_cache_get(handle, "k", 1);
        lc_require(kiln_cache_found() == 1);
    }
    fail_key_create = create_failure;
    fail_key_set = !create_failure;
    lc_require(kiln_cache_set(handle, "k", 1, value, sizeof(value), 0) == 1);
    kiln_cache_get(handle, "k", 1);
    lc_require(kiln_cache_found() == -2 && sp_ffi_bin_len == 0);
    fail_key_set = 0;
    if (!create_failure) {
        const char *result = kiln_cache_get(handle, "k", 1);
        lc_require(kiln_cache_found() == 1 && sp_ffi_bin_len == sizeof(value));
        lc_require(memcmp(result, value, sizeof(value)) == 0);
    }
    lc_require(kiln_cache_free(handle) == 0);
    puts("cache TLS: pthread failure is reported without losing the existing buffer");
}

static void test_generation(void) {
    long handle = kiln_cache_new(1, 8, 65536, 1024);
    uint32_t gen = 0;
    kc_slot *slot = kc_slot_of(handle, &gen);
    lc_require(slot && kiln_cache_free(handle) == 0);
    atomic_store(&slot->state, (uint64_t)KC_GEN_MAX << 32);
    long replacement = kiln_cache_new(1, 8, 65536, 1024);
    uint32_t replacement_gen = 0;
    kc_slot *other = kc_slot_of(replacement, &replacement_gen);
    lc_require(other && other != slot && replacement != handle);
    lc_require(kiln_cache_set(handle, "k", 1, "v", 1, 0) == -1);
    uint64_t full = ((uint64_t)replacement_gen << 32) | KC_LIVE | KC_USERS;
    atomic_store(&other->state, full);
    kiln_cache_get(replacement, "k", 1);
    lc_require(kiln_cache_found() == -1 && atomic_load(&other->state) == full);
    atomic_store(&other->state, ((uint64_t)replacement_gen << 32) | KC_LIVE);
    lc_require(kiln_cache_stats_read(replacement) == KILN_CACHE_STATS);
    lc_require(kiln_cache_stat(0) == 0 && kiln_cache_stat(-1) == -1);
    lc_require(kiln_cache_open(replacement) == 1 && kiln_cache_free(replacement) == 0);
    puts("cache generations: exhausted slots retire; reader counts cannot overflow; snapshots "
         "passed");
}

static void test_busy(void) {
    long handle = kiln_cache_new(1, 8, 65536, 1024);
    lc_require(handle >= 0 && kiln_cache_set(handle, "k", 1, "v", 1, 0) == 1);
    kc_slot *held = NULL;
    kc_cache *cache = kc_acquire(handle, &held);
    lc_require(cache != NULL);
    int64_t before[KILN_CACHE_STATS], after[KILN_CACHE_STATS];
    lc_require(kiln_cache_stats(handle, before, KILN_CACHE_STATS) == KILN_CACHE_STATS);
    pthread_mutex_lock(&cache->shards[0].lock);
    kiln_cache_get_try(handle, "k", 1);
    lc_require(kiln_cache_found() == KILN_CACHE_BUSY && sp_ffi_bin_len == 0);
    lc_require(kiln_cache_set_try(handle, "k", 1, "w", 1, 0) == KILN_CACHE_BUSY);
    lc_require(kiln_cache_set_try(handle, "big", 3, "x", 2000, 0) == KILN_CACHE_BUSY);
    lc_require(kiln_cache_delete_try(handle, "k", 1) == KILN_CACHE_BUSY);
    pthread_mutex_unlock(&cache->shards[0].lock);
    kc_release(held);
    lc_require(kiln_cache_stats(handle, after, KILN_CACHE_STATS) == KILN_CACHE_STATS);
    lc_require(memcmp(before, after, sizeof(before)) == 0);
    const char *value = kiln_cache_get_try(handle, "k", 1);
    lc_require(kiln_cache_found() == 1 && sp_ffi_bin_len == 1 && value[0] == 'v');
    lc_require(kiln_cache_set_try(handle, "k", 1, "w", 1, 0) == 1);
    lc_require(kiln_cache_delete_try(handle, "k", 1) == 1);
    lc_require(kiln_cache_free(handle) == 0);
    lc_require(kiln_cache_set_try(handle, "k", 1, "w", 1, 0) == -1);
    lc_require(kiln_cache_delete_try(handle, "k", 1) == -1);
    kiln_cache_get_try(handle, "k", 1);
    lc_require(kiln_cache_found() == -1);
    puts("cache busy: try calls report a held shard and change nothing");
}

int main(int argc, char **argv) {
    if (argc > 1) {
        test_tls_failure(strcmp(argv[1], "key-create") == 0);
    } else {
        test_limits();
        test_close();
        test_generation();
        test_busy();
    }
    return 0;
}
