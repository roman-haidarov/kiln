#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <time.h>

static pthread_mutex_t *gc_target;
static _Atomic int gc_ready, gc_reader_waiting;

static int gc_shard_lock(pthread_mutex_t *lock) {
    if (atomic_load(&gc_ready) && lock == gc_target) {
        atomic_store(&gc_reader_waiting, 1);
    }
    return pthread_mutex_lock(lock);
}

#define pthread_mutex_lock gc_shard_lock
#include "../ext/kiln_cache.c"
#undef pthread_mutex_lock

static pthread_mutex_t gc_control = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t gc_changed = PTHREAD_COND_INITIALIZER;
static pthread_t gc_holder;
static _Atomic int gc_expired;
static int gc_release_holder;
static long gc_handle;

static void *gc_hold(void *unused) {
    (void)unused;
    kc_slot *held = NULL;
    kc_cache *cache = kc_acquire(gc_handle, &held);
    if (!cache) {
        return NULL;
    }
    gc_target = &cache->shards[0].lock;
    pthread_mutex_lock(&cache->shards[0].lock);
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += 5;
    pthread_mutex_lock(&gc_control);
    atomic_store(&gc_ready, 1);
    while (!gc_release_holder) {
        if (pthread_cond_timedwait(&gc_changed, &gc_control, &deadline) == ETIMEDOUT) {
            atomic_store(&gc_expired, 1);
            break;
        }
    }
    pthread_mutex_unlock(&gc_control);
    pthread_mutex_unlock(&cache->shards[0].lock);
    kc_release(held);
    return NULL;
}

long cache_gc_start(long handle) {
    gc_handle = handle;
    return pthread_create(&gc_holder, NULL, gc_hold, NULL);
}

long cache_gc_waiting(void) {
    return atomic_load(&gc_reader_waiting);
}

long cache_gc_release(void) {
    pthread_mutex_lock(&gc_control);
    gc_release_holder = 1;
    pthread_cond_broadcast(&gc_changed);
    pthread_mutex_unlock(&gc_control);
    return atomic_load(&gc_expired);
}

long cache_gc_join(void) {
    return pthread_join(gc_holder, NULL);
}
