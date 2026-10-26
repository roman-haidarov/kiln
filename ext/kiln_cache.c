#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#ifdef __APPLE__
#include <sys/random.h>
#else
#include <unistd.h>
#endif
#include "kiln_cache.h"
#include "rapidhash/rapidhash.h"

#define KC_MAX_CACHES   64
#define KC_MAX_SHARDS   256
#define KC_SCAN_BUDGET  64
#define KC_EVICT_BUDGET 64
#define KC_SWEEP_CHUNK  64
#define KC_LINE         64
#define KC_SLOT_BITS    6
#define KC_GEN_MAX      0x7fffffffu
#define KC_LIVE         1u
#define KC_CLOSING      2u
#define KC_USER         4u
#define KC_USERS        0xfffffffcu
#define KC_BUSY         KILN_CACHE_BUSY

typedef struct kc_entry {
    struct kc_entry *newer;
    struct kc_entry *older;
    const char *key;
    uint64_t hash;
    int64_t expires;
    uint32_t klen;
    uint32_t vlen;
    uint8_t visited;
    char data[];
} kc_entry;

typedef struct {
    int frozen;
} kc_alloc;

static void *kc_table_malloc(size_t size, const kc_alloc *ctx) {
    return ctx->frozen ? NULL : malloc(size);
}

static void kc_table_free(void *ptr, size_t size, kc_alloc *ctx) {
    (void)size;
    (void)ctx;
    free(ptr);
}

static uint64_t kc_entry_hash(const kc_entry *entry) {
    return entry->hash;
}

static bool kc_entry_same(const kc_entry *left, const kc_entry *right) {
    if (left->hash != right->hash || left->klen != right->klen) {
        return false;
    }
    if (left->klen == 0) {
        return true;
    }
    return memcmp(left->key, right->key, left->klen) == 0;
}

#define NAME      kc_index
#define KEY_TY    kc_entry *
#define HASH_FN   kc_entry_hash
#define CMPR_FN   kc_entry_same
#define CTX_TY    kc_alloc
#define MALLOC_FN kc_table_malloc
#define FREE_FN   kc_table_free
#include "verstable/verstable.h"

typedef struct {
    _Alignas(KC_LINE) pthread_mutex_t lock;
    kc_index index;
    kc_entry *newest;
    kc_entry *oldest;
    kc_entry *hand;
    kc_entry *sweep;
    size_t count;
    size_t bytes;
    size_t max_count;
    size_t max_bytes;
    uint64_t hits;
    uint64_t misses;
    uint64_t evictions;
    uint64_t expirations;
    uint64_t refusals;
} kc_shard;

typedef struct {
    uint64_t seed;
    size_t max_value;
    uint32_t mask;
    uint32_t shard_count;
    _Atomic uint32_t sweep_start;
    kc_shard *shards;
} kc_cache;

typedef struct {
    _Atomic uint64_t state;
    _Atomic(kc_cache *) cache;
} kc_slot;

static kc_slot kc_slots[KC_MAX_CACHES];
static pthread_mutex_t kc_registry = PTHREAD_MUTEX_INITIALIZER;

#ifdef SP_THREADS
extern __thread int sp_ffi_bin_len;
static __thread char *kc_out;
static __thread size_t kc_out_cap;
static __thread long kc_found;
static __thread int64_t kc_snapshot[KILN_CACHE_STATS];
#else
extern int sp_ffi_bin_len;
static char *kc_out;
static size_t kc_out_cap;
static long kc_found;
static int64_t kc_snapshot[KILN_CACHE_STATS];
#endif

static const char kc_empty[1] = {0};
static pthread_key_t kc_out_key;
static pthread_once_t kc_out_once = PTHREAD_ONCE_INIT;
static int kc_out_key_ready;

static void kc_out_release(void *buffer) {
    free(buffer);
}

static void kc_out_key_init(void) {
    kc_out_key_ready = pthread_key_create(&kc_out_key, kc_out_release) == 0;
}

static int64_t kc_now_ms(void) {
    struct timespec ts = {0};
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        return INT64_MAX;
    }
    return ((int64_t)ts.tv_sec * 1000) + (ts.tv_nsec / 1000000);
}

static int64_t kc_deadline(long ttl_ms) {
    int64_t now = kc_now_ms();
    return (int64_t)ttl_ms > INT64_MAX - now ? INT64_MAX : now + (int64_t)ttl_ms;
}

static int kc_expired(const kc_entry *entry, int64_t *now) {
    if (entry->expires == 0) {
        return 0;
    }
    if (*now == 0) {
        *now = kc_now_ms();
    }
    return entry->expires <= *now;
}

static size_t kc_size(const kc_entry *entry) {
    return sizeof(kc_entry) + entry->klen + entry->vlen;
}

static kc_slot *kc_slot_of(long handle, uint32_t *gen) {
    if (handle <= 0) {
        return NULL;
    }
    uint64_t generation = (uint64_t)handle >> KC_SLOT_BITS;
    if (generation == 0 || generation > KC_GEN_MAX) {
        return NULL;
    }
    *gen = (uint32_t)generation;
    return &kc_slots[handle & (KC_MAX_CACHES - 1)];
}

static int kc_open_in(uint64_t state, uint32_t gen) {
    return (uint32_t)(state >> 32) == gen && (state & (KC_LIVE | KC_CLOSING)) == KC_LIVE;
}

long kiln_cache_open(long handle) {
    uint32_t gen = 0;
    kc_slot *slot = kc_slot_of(handle, &gen);
    return slot && kc_open_in(atomic_load_explicit(&slot->state, memory_order_acquire), gen);
}

static kc_cache *kc_acquire(long handle, kc_slot **held) {
    uint32_t gen = 0;
    kc_slot *slot = kc_slot_of(handle, &gen);
    if (!slot) {
        return NULL;
    }
    uint64_t state = atomic_load_explicit(&slot->state, memory_order_acquire);
    do {
        if (!kc_open_in(state, gen) || (state & KC_USERS) == KC_USERS) {
            return NULL;
        }
    } while (!atomic_compare_exchange_weak_explicit(
        &slot->state, &state, state + KC_USER, memory_order_acquire, memory_order_acquire));
    *held = slot;
    return atomic_load_explicit(&slot->cache, memory_order_acquire);
}

static void kc_release(kc_slot *slot) {
    atomic_fetch_sub_explicit(&slot->state, KC_USER, memory_order_release);
}

static uint64_t kc_hash(const kc_cache *cache, const char *key, size_t klen) {
    return rapidhash_withSeed(klen ? key : kc_empty, klen, cache->seed);
}

static kc_shard *kc_shard_of(const kc_cache *cache, uint64_t hash) {
    return &cache->shards[(hash >> 40) & cache->mask];
}

static void kc_link(kc_shard *shard, kc_entry *entry) {
    entry->older = shard->newest;
    entry->newer = NULL;
    if (shard->newest) {
        shard->newest->newer = entry;
    } else {
        shard->oldest = entry;
    }
    shard->newest = entry;
}

static void kc_unlink(kc_shard *shard, kc_entry *entry) {
    if (shard->hand == entry) {
        shard->hand = entry->newer;
    }
    if (shard->sweep == entry) {
        shard->sweep = entry->newer;
    }
    if (entry->newer) {
        entry->newer->older = entry->older;
    } else {
        shard->newest = entry->older;
    }
    if (entry->older) {
        entry->older->newer = entry->newer;
    } else {
        shard->oldest = entry->newer;
    }
}

static void kc_drop(kc_shard *shard, kc_entry *entry) {
    kc_index_erase(&shard->index, entry);
    kc_unlink(shard, entry);
    shard->count--;
    shard->bytes -= kc_size(entry);
}

static kc_entry *kc_find(kc_shard *shard, const char *key, size_t klen, uint64_t hash) {
    kc_entry probe;
    probe.key = klen ? key : kc_empty;
    probe.klen = (uint32_t)klen;
    probe.hash = hash;
    kc_index_itr itr = kc_index_get(&shard->index, &probe);
    if (kc_index_is_end(itr)) {
        return NULL;
    }
    return itr.data->key;
}

static kc_entry *kc_victim(kc_shard *shard, int64_t *now) {
    kc_entry *node = shard->hand ? shard->hand : shard->oldest;
    for (int step = 0; node && step < KC_SCAN_BUDGET; step++) {
        if (!node->visited || kc_expired(node, now)) {
            return node;
        }
        node->visited = 0;
        node = node->newer ? node->newer : shard->oldest;
    }
    return node ? node : shard->oldest;
}

static void kc_free_all(kc_entry **garbage, int count) {
    for (int i = 0; i < count; i++) {
        free(garbage[i]);
    }
}

static int kc_over(const kc_shard *shard, size_t need) {
    return shard->count >= shard->max_count || need > shard->max_bytes - shard->bytes;
}

static kc_entry *kc_entry_new(
    const char *key, size_t klen, const char *val, size_t vlen, uint64_t hash, long ttl_ms) {
    kc_entry *entry = malloc(sizeof(kc_entry) + klen + vlen);
    if (!entry) {
        return NULL;
    }
    if (klen) {
        memcpy(entry->data, key, klen);
    }
    if (vlen) {
        memcpy(entry->data + klen, val, vlen);
    }
    entry->key = entry->data;
    entry->klen = (uint32_t)klen;
    entry->vlen = (uint32_t)vlen;
    entry->hash = hash;
    entry->visited = 0;
    entry->expires = ttl_ms > 0 ? kc_deadline(ttl_ms) : 0;
    entry->newer = NULL;
    entry->older = NULL;
    return entry;
}

static int kc_store(kc_shard *shard, kc_entry *entry, kc_entry **garbage, int *dropped) {
    int64_t now = 0;
    size_t need = kc_size(entry);
    kc_entry *old = kc_find(shard, entry->key, entry->klen, entry->hash);
    if (old) {
        kc_drop(shard, old);
        garbage[(*dropped)++] = old;
    }
    int evicted = 0;
    while (kc_over(shard, need) && shard->count > 0 && evicted < KC_EVICT_BUDGET) {
        kc_entry *victim = kc_victim(shard, &now);
        if (kc_expired(victim, &now)) {
            shard->expirations++;
        } else {
            shard->evictions++;
        }
        shard->hand = victim;
        kc_drop(shard, victim);
        garbage[(*dropped)++] = victim;
        evicted++;
    }
    if (kc_over(shard, need) || kc_index_is_end(kc_index_insert(&shard->index, entry))) {
        shard->refusals++;
        return 0;
    }
    kc_link(shard, entry);
    shard->count++;
    shard->bytes += need;
    return 1;
}

static int kc_lock(kc_shard *shard, int try_lock) {
    if (try_lock) {
        return pthread_mutex_trylock(&shard->lock) == 0;
    }
    pthread_mutex_lock(&shard->lock);
    return 1;
}

static long kc_refuse(kc_shard *shard, const char *key, size_t klen, uint64_t hash, int try_lock) {
    if (!kc_lock(shard, try_lock)) {
        return KC_BUSY;
    }
    kc_entry *old = kc_find(shard, key, klen, hash);
    if (old) {
        kc_drop(shard, old);
    }
    shard->refusals++;
    pthread_mutex_unlock(&shard->lock);
    free(old);
    return 0;
}

static long kc_set(const kc_cache *cache, const char *key, long klen, const char *val, long vlen,
    long ttl_ms, int try_lock) {
    if (klen > KILN_CACHE_MAX_KEY) {
        return 0;
    }
    uint64_t hash = kc_hash(cache, key, (size_t)klen);
    kc_shard *shard = kc_shard_of(cache, hash);
    kc_entry *entry = NULL;
    if ((size_t)vlen <= cache->max_value &&
        sizeof(kc_entry) + (size_t)klen + (size_t)vlen <= shard->max_bytes) {
        entry = kc_entry_new(key, (size_t)klen, val, (size_t)vlen, hash, ttl_ms);
    }
    if (!entry) {
        return kc_refuse(shard, key, (size_t)klen, hash, try_lock);
    }
    kc_entry *garbage[KC_EVICT_BUDGET + 1];
    int dropped = 0;
    if (!kc_lock(shard, try_lock)) {
        free(entry);
        return KC_BUSY;
    }
    int stored = kc_store(shard, entry, garbage, &dropped);
    pthread_mutex_unlock(&shard->lock);
    kc_free_all(garbage, dropped);
    if (!stored) {
        free(entry);
    }
    return stored;
}

static long kc_set_call(long handle, const char *key, long klen, const char *val, long vlen,
    long ttl_ms, int try_lock) {
    if (klen < 0 || vlen < 0 || (klen && !key) || (vlen && !val)) {
        return -1;
    }
    kc_slot *slot = NULL;
    const kc_cache *cache = kc_acquire(handle, &slot);
    if (!cache) {
        return -1;
    }
    long stored = kc_set(cache, key, klen, val, vlen, ttl_ms, try_lock);
    kc_release(slot);
    return stored;
}

long kiln_cache_set(
    long handle, const char *key, long klen, const char *val, long vlen, long ttl_ms) {
    return kc_set_call(handle, key, klen, val, vlen, ttl_ms, 0);
}

long kiln_cache_set_try(
    long handle, const char *key, long klen, const char *val, long vlen, long ttl_ms) {
    return kc_set_call(handle, key, klen, val, vlen, ttl_ms, 1);
}

static int kc_out_reserve(size_t size) {
    if (size <= kc_out_cap) {
        return 1;
    }
    size_t cap = kc_out_cap ? kc_out_cap : 256;
    while (cap < size) {
        if (cap > SIZE_MAX / 2) {
            return 0;
        }
        cap *= 2;
    }
    if (pthread_once(&kc_out_once, kc_out_key_init) != 0 || !kc_out_key_ready) {
        return 0;
    }
    char *grown = malloc(cap);
    if (!grown) {
        return 0;
    }
    if (pthread_setspecific(kc_out_key, grown) != 0) {
        free(grown);
        return 0;
    }
    free(kc_out);
    kc_out = grown;
    kc_out_cap = cap;
    return 1;
}

static const char *kc_get(const kc_cache *cache, const char *key, long klen, int try_lock) {
    kc_found = 0;
    if (klen > KILN_CACHE_MAX_KEY) {
        return kc_empty;
    }
    uint64_t hash = kc_hash(cache, key, (size_t)klen);
    kc_shard *shard = kc_shard_of(cache, hash);
    for (;;) {
        int64_t now = 0;
        kc_entry *stale = NULL;
        size_t want = 0;
        if (!kc_lock(shard, try_lock)) {
            kc_found = KC_BUSY;
            return kc_empty;
        }
        kc_entry *entry = kc_find(shard, key, (size_t)klen, hash);
        if (entry && kc_expired(entry, &now)) {
            kc_drop(shard, entry);
            shard->expirations++;
            stale = entry;
            entry = NULL;
        }
        if (!entry) {
            shard->misses++;
        } else if (entry->vlen > kc_out_cap) {
            want = entry->vlen;
        } else {
            entry->visited = 1;
            shard->hits++;
            if (entry->vlen) {
                memcpy(kc_out, entry->data + entry->klen, entry->vlen);
            }
            sp_ffi_bin_len = (int)entry->vlen;
            kc_found = 1;
        }
        pthread_mutex_unlock(&shard->lock);
        free(stale);
        if (!want) {
            return kc_found == 1 && kc_out ? kc_out : kc_empty;
        }
        if (!kc_out_reserve(want)) {
            kc_found = -2;
            return kc_empty;
        }
    }
}

static const char *kc_get_call(long handle, const char *key, long klen, int try_lock) {
    sp_ffi_bin_len = 0;
    kc_found = -1;
    if (klen < 0 || (klen && !key)) {
        return kc_empty;
    }
    kc_slot *slot = NULL;
    const kc_cache *cache = kc_acquire(handle, &slot);
    if (!cache) {
        return kc_empty;
    }
    const char *out = kc_get(cache, key, klen, try_lock);
    kc_release(slot);
    return out;
}

const char *kiln_cache_get(long handle, const char *key, long klen) {
    return kc_get_call(handle, key, klen, 0);
}

const char *kiln_cache_get_try(long handle, const char *key, long klen) {
    return kc_get_call(handle, key, klen, 1);
}

long kiln_cache_found(void) {
    return kc_found;
}

static long kc_delete(const kc_cache *cache, const char *key, long klen, int try_lock) {
    if (klen > KILN_CACHE_MAX_KEY) {
        return 0;
    }
    uint64_t hash = kc_hash(cache, key, (size_t)klen);
    kc_shard *shard = kc_shard_of(cache, hash);
    if (!kc_lock(shard, try_lock)) {
        return KC_BUSY;
    }
    kc_entry *entry = kc_find(shard, key, (size_t)klen, hash);
    if (entry) {
        kc_drop(shard, entry);
    }
    pthread_mutex_unlock(&shard->lock);
    long removed = entry ? 1 : 0;
    free(entry);
    return removed;
}

static long kc_delete_call(long handle, const char *key, long klen, int try_lock) {
    if (klen < 0 || (klen && !key)) {
        return -1;
    }
    kc_slot *slot = NULL;
    const kc_cache *cache = kc_acquire(handle, &slot);
    if (!cache) {
        return -1;
    }
    long removed = kc_delete(cache, key, klen, try_lock);
    kc_release(slot);
    return removed;
}

long kiln_cache_delete(long handle, const char *key, long klen) {
    return kc_delete_call(handle, key, klen, 0);
}

long kiln_cache_delete_try(long handle, const char *key, long klen) {
    return kc_delete_call(handle, key, klen, 1);
}

static long kc_sweep_shard(kc_shard *shard, long steps) {
    long removed = 0;
    while (steps > 0) {
        kc_entry *garbage[KC_SWEEP_CHUNK];
        int dropped = 0;
        long seen = 0;
        int64_t now = 0;
        pthread_mutex_lock(&shard->lock);
        kc_entry *node = shard->sweep ? shard->sweep : shard->oldest;
        while (node && seen < steps && seen < KC_SWEEP_CHUNK) {
            kc_entry *next = node->newer;
            if (kc_expired(node, &now)) {
                kc_drop(shard, node);
                shard->expirations++;
                garbage[dropped++] = node;
            }
            node = next;
            seen++;
        }
        shard->sweep = node;
        pthread_mutex_unlock(&shard->lock);
        kc_free_all(garbage, dropped);
        removed += dropped;
        steps -= seen;
        if (!node) {
            break;
        }
    }
    return removed;
}

static long kc_sweep(kc_cache *cache, long budget) {
    long removed = 0;
    long count = (long)cache->shard_count;
    long per = budget / count;
    long extra = budget % count;
    uint32_t start = atomic_fetch_add_explicit(&cache->sweep_start, 1, memory_order_relaxed);
    for (long i = 0; i < count; i++) {
        long steps = per + (i < extra ? 1 : 0);
        if (steps > 0) {
            removed += kc_sweep_shard(&cache->shards[(start + (uint32_t)i) & cache->mask], steps);
        }
    }
    return removed;
}

long kiln_cache_sweep(long handle, long budget) {
    if (budget < 0) {
        return -1;
    }
    kc_slot *slot = NULL;
    kc_cache *cache = kc_acquire(handle, &slot);
    if (!cache) {
        return -1;
    }
    long removed = budget > 0 ? kc_sweep(cache, budget) : 0;
    kc_release(slot);
    return removed;
}

static long kc_free_list(kc_entry *node) {
    long freed = 0;
    while (node) {
        kc_entry *next = node->newer;
        free(node);
        node = next;
        freed++;
    }
    return freed;
}

static long kc_clear(kc_cache *cache) {
    long removed = 0;
    for (uint32_t i = 0; i < cache->shard_count; i++) {
        kc_shard *shard = &cache->shards[i];
        pthread_mutex_lock(&shard->lock);
        kc_entry *list = shard->oldest;
        kc_index_clear(&shard->index);
        shard->newest = NULL;
        shard->oldest = NULL;
        shard->hand = NULL;
        shard->sweep = NULL;
        shard->count = 0;
        shard->bytes = 0;
        pthread_mutex_unlock(&shard->lock);
        removed += kc_free_list(list);
    }
    return removed;
}

long kiln_cache_clear(long handle) {
    kc_slot *slot = NULL;
    kc_cache *cache = kc_acquire(handle, &slot);
    if (!cache) {
        return -1;
    }
    long removed = kc_clear(cache);
    kc_release(slot);
    return removed;
}

static void kc_stats(kc_cache *cache, int64_t *out) {
    int64_t totals[KILN_CACHE_STATS] = {0};
    for (uint32_t i = 0; i < cache->shard_count; i++) {
        kc_shard *shard = &cache->shards[i];
        pthread_mutex_lock(&shard->lock);
        totals[0] += (int64_t)shard->count;
        totals[1] += (int64_t)shard->bytes;
        totals[2] += (int64_t)shard->hits;
        totals[3] += (int64_t)shard->misses;
        totals[4] += (int64_t)shard->evictions;
        totals[5] += (int64_t)shard->expirations;
        totals[6] += (int64_t)shard->refusals;
        pthread_mutex_unlock(&shard->lock);
    }
    memcpy(out, totals, sizeof(totals));
}

long kiln_cache_stats(long handle, int64_t *out, long cap) {
    if (!out || cap < KILN_CACHE_STATS) {
        return -1;
    }
    kc_slot *slot = NULL;
    kc_cache *cache = kc_acquire(handle, &slot);
    if (!cache) {
        return -1;
    }
    kc_stats(cache, out);
    kc_release(slot);
    return KILN_CACHE_STATS;
}

long kiln_cache_stats_read(long handle) {
    return kiln_cache_stats(handle, kc_snapshot, KILN_CACHE_STATS);
}

long kiln_cache_stat(long index) {
    return index >= 0 && index < KILN_CACHE_STATS ? (long)kc_snapshot[index] : -1;
}

static uint64_t kc_seed(void) {
    uint64_t seed = 0;
    if (getentropy(&seed, sizeof(seed)) != 0) {
        struct timespec ts = {0};
        clock_gettime(CLOCK_REALTIME, &ts);
        seed = ((uint64_t)ts.tv_sec << 32) ^ (uint64_t)ts.tv_nsec ^ (uint64_t)(uintptr_t)&seed;
    }
    return seed;
}

static void kc_destroy(kc_cache *cache, uint32_t ready) {
    for (uint32_t i = 0; i < ready; i++) {
        kc_shard *shard = &cache->shards[i];
        kc_free_list(shard->oldest);
        kc_index_cleanup(&shard->index);
        pthread_mutex_destroy(&shard->lock);
    }
    free(cache->shards);
    free(cache);
}

static int kc_shard_init(kc_shard *shard, size_t max_count, size_t max_bytes) {
    memset(shard, 0, sizeof(*shard));
    if (pthread_mutex_init(&shard->lock, NULL) != 0) {
        return 0;
    }
    kc_index_init(&shard->index, (kc_alloc){0});
    if (!kc_index_reserve(&shard->index, max_count)) {
        kc_index_cleanup(&shard->index);
        pthread_mutex_destroy(&shard->lock);
        return 0;
    }
    shard->index.ctx.frozen = 1;
    shard->max_count = max_count;
    shard->max_bytes = max_bytes;
    return 1;
}

static long kc_register(kc_cache *cache) {
    long handle = -1;
    pthread_mutex_lock(&kc_registry);
    for (long i = 0; i < KC_MAX_CACHES; i++) {
        kc_slot *slot = &kc_slots[i];
        uint64_t state = atomic_load_explicit(&slot->state, memory_order_acquire);
        if ((uint32_t)state != 0) {
            continue;
        }
        uint32_t previous = (uint32_t)(state >> 32);
        if (previous >= KC_GEN_MAX) {
            atomic_store_explicit(&slot->state, UINT64_MAX, memory_order_release);
            continue;
        }
        uint32_t gen = previous + 1;
        atomic_store_explicit(&slot->cache, cache, memory_order_relaxed);
        atomic_store_explicit(&slot->state, ((uint64_t)gen << 32) | KC_LIVE, memory_order_release);
        handle = ((long)gen << KC_SLOT_BITS) | i;
        break;
    }
    pthread_mutex_unlock(&kc_registry);
    return handle;
}

long kiln_cache_new(long shards, long max_entries, long max_bytes, long max_value) {
    if (shards < 1 || shards > KC_MAX_SHARDS || (shards & (shards - 1)) != 0 ||
        max_entries < shards || max_entries > KILN_CACHE_MAX_ENTRIES || max_bytes < shards ||
        max_value < 0 || max_value > KILN_CACHE_MAX_VALUE) {
        return -2;
    }
    kc_cache *cache = calloc(1, sizeof(kc_cache));
    if (!cache) {
        return -1;
    }
    void *memory = NULL;
    if (posix_memalign(&memory, KC_LINE, sizeof(kc_shard) * (size_t)shards) != 0) {
        free(cache);
        return -1;
    }
    cache->shards = memory;
    cache->seed = kc_seed();
    cache->max_value = (size_t)max_value;
    cache->mask = (uint32_t)shards - 1;
    cache->shard_count = (uint32_t)shards;
    size_t per_count = (size_t)(max_entries / shards);
    size_t per_bytes = (size_t)(max_bytes / shards);
    for (uint32_t i = 0; i < cache->shard_count; i++) {
        if (!kc_shard_init(&cache->shards[i], per_count, per_bytes)) {
            kc_destroy(cache, i);
            return -1;
        }
    }
    long handle = kc_register(cache);
    if (handle < 0) {
        kc_destroy(cache, cache->shard_count);
    }
    return handle;
}

long kiln_cache_free(long handle) {
    uint32_t gen = 0;
    kc_slot *slot = kc_slot_of(handle, &gen);
    if (!slot) {
        return -1;
    }
    uint64_t state = atomic_load_explicit(&slot->state, memory_order_acquire);
    do {
        if (!kc_open_in(state, gen)) {
            return -1;
        }
    } while (!atomic_compare_exchange_weak_explicit(
        &slot->state, &state, state | KC_CLOSING, memory_order_acq_rel, memory_order_acquire));
    while (atomic_load_explicit(&slot->state, memory_order_acquire) & KC_USERS) {
        sched_yield();
    }
    kc_cache *cache = atomic_exchange_explicit(&slot->cache, NULL, memory_order_acq_rel);
    kc_destroy(cache, cache->shard_count);
    atomic_store_explicit(&slot->state, (uint64_t)gen << 32, memory_order_release);
    return 0;
}
