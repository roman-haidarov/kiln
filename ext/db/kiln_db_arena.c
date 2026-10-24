#include "kiln_db.h"

#include <pthread.h>
#include <sched.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    _Alignas(64) int state;
    int kind;
    uint32_t generation;
    uint64_t scope;
    uint64_t thread_id;
    void *ptr;
    uint32_t pins;
    int lock;
} db_slot;

typedef struct {
    uint32_t generation;
    uint64_t scope;
    uint64_t thread_id;
} db_arena;

static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static kiln_db_limits lim;
static int ready;
static db_slot *slots;
static int64_t metric_values[KILN_DB_METRIC_N];

static void slot_lock(db_slot *slot) {
    int spins = 0;
    while (__atomic_exchange_n(&slot->lock, 1, __ATOMIC_ACQUIRE)) {
        if (++spins >= 64) {
            spins = 0;
            sched_yield();
        }
    }
}

static void slot_unlock(db_slot *slot) {
    __atomic_store_n(&slot->lock, 0, __ATOMIC_RELEASE);
}

static int slot_check(
    const db_slot *slot, uint32_t gen, int kind, uint64_t scope, uint64_t thread_id) {
    if (slot->state != KILN_DB_SLOT_LIVE || slot->generation != gen || slot->kind != kind) {
        return KILN_DB_STALE;
    }
    if (slot->scope != scope || slot->thread_id != thread_id) {
        return KILN_DB_OWNERSHIP;
    }
    return KILN_DB_OK;
}

static int limits_same(const kiln_db_limits *a, const kiln_db_limits *b) {
    return a->max_live_slots == b->max_live_slots && a->block_rows == b->block_rows &&
           a->max_error_bytes == b->max_error_bytes &&
           a->max_payload_bytes == b->max_payload_bytes &&
           a->max_resolver_queue == b->max_resolver_queue &&
           a->max_pipeline_inflight == b->max_pipeline_inflight &&
           a->max_dirty_groups == b->max_dirty_groups && a->copy_min_rows == b->copy_min_rows;
}

static int limits_ok(const kiln_db_limits *v) {
    if (!v || v->max_live_slots == 0 || v->max_live_slots == UINT32_MAX) {
        return 0;
    }
    if (v->block_rows == 0 || v->max_error_bytes == 0 || v->max_payload_bytes == 0) {
        return 0;
    }
    if (v->max_resolver_queue == 0 || v->max_resolver_queue == UINT32_MAX) {
        return 0;
    }
    if (v->max_pipeline_inflight == 0 || v->max_dirty_groups == 0 || v->copy_min_rows == 0) {
        return 0;
    }
    return 1;
}

int kiln_db_configure(const kiln_db_limits *next) {
    if (!limits_ok(next)) {
        return KILN_DB_CONFIG;
    }
    pthread_mutex_lock(&mu);
    if (ready) {
        int same = limits_same(&lim, next);
        pthread_mutex_unlock(&mu);
        return same ? KILN_DB_OK : KILN_DB_CONFIG;
    }
    lim = *next;
    slots = aligned_alloc(64, ((size_t)lim.max_live_slots + 1u) * sizeof *slots);
    if (slots) {
        memset(slots, 0, ((size_t)lim.max_live_slots + 1u) * sizeof *slots);
    }
    if (!slots) {
        pthread_mutex_unlock(&mu);
        return KILN_DB_CAPACITY;
    }
    ready = 1;
    pthread_mutex_unlock(&mu);
    return KILN_DB_OK;
}

int kiln_db_is_ready(void) {
    int value;
    pthread_mutex_lock(&mu);
    value = ready;
    pthread_mutex_unlock(&mu);
    return value;
}

const kiln_db_limits *kiln_db_limits_get(void) {
    return ready ? &lim : NULL;
}

void kiln_db_metric_add(int id, int64_t delta) {
    if (id < 0 || id >= KILN_DB_METRIC_N) {
        return;
    }
    __atomic_fetch_add(&metric_values[id], delta, __ATOMIC_RELAXED);
}

void kiln_db_metrics(int64_t *out, int n) {
    int i;
    int keep = n < KILN_DB_METRIC_N ? n : KILN_DB_METRIC_N;
    if (!out || keep <= 0) {
        return;
    }
    for (i = 0; i < keep; i++) {
        out[i] = __atomic_load_n(&metric_values[i], __ATOMIC_RELAXED);
    }
}

void kiln_db_metrics_reset_test(void) {
    int i;
    for (i = 0; i < KILN_DB_METRIC_N; i++) {
        __atomic_store_n(&metric_values[i], 0, __ATOMIC_RELAXED);
    }
}

uint64_t kiln_db_slot_put(int kind, void *ptr, uint64_t scope, uint64_t thread_id, int *err) {
    uint32_t i;
    if (!err) {
        return 0;
    }
    if (!ready) {
        *err = KILN_DB_CONFIG;
        return 0;
    }
    if (!ptr ||
        (kind != KILN_DB_SLOT_CONN && kind != KILN_DB_SLOT_BLOCK && kind != KILN_DB_SLOT_ARENA)) {
        *err = KILN_DB_ERR;
        return 0;
    }
    pthread_mutex_lock(&mu);
    for (i = 1; i <= lim.max_live_slots; i++) {
        uint64_t handle;
        if (slots[i].state != KILN_DB_SLOT_FREE) {
            continue;
        }
        slot_lock(&slots[i]);
        if (slots[i].generation == 0) {
            slots[i].generation = 1;
        }
        slots[i].state = KILN_DB_SLOT_LIVE;
        slots[i].kind = kind;
        slots[i].ptr = ptr;
        slots[i].pins = 0;
        slots[i].scope = scope;
        slots[i].thread_id = thread_id;
        handle = ((uint64_t)slots[i].generation << 32) | (uint64_t)i;
        slot_unlock(&slots[i]);
        pthread_mutex_unlock(&mu);
        *err = KILN_DB_OK;
        return handle;
    }
    pthread_mutex_unlock(&mu);
    *err = KILN_DB_CAPACITY;
    return 0;
}

void *kiln_db_slot_use(uint64_t handle, int kind, uint64_t scope, uint64_t thread_id, int *err) {
    uint32_t id = (uint32_t)handle;
    uint32_t gen = (uint32_t)(handle >> 32);
    db_slot *slot;
    void *ptr = NULL;
    int rc;
    if (!err) {
        return NULL;
    }
    if (!ready || id == 0 || gen == 0 || id > lim.max_live_slots) {
        *err = KILN_DB_STALE;
        kiln_db_metric_add(KILN_DB_METRIC_STALE, 1);
        return NULL;
    }
    slot = &slots[id];
    slot_lock(slot);
    rc = slot_check(slot, gen, kind, scope, thread_id);
    if (rc == KILN_DB_OK) {
        ptr = slot->ptr;
    }
    slot_unlock(slot);
    if (rc == KILN_DB_STALE) {
        kiln_db_metric_add(KILN_DB_METRIC_STALE, 1);
    }
    *err = rc;
    return ptr;
}

int kiln_db_slot_pin(uint64_t handle, int kind, uint64_t scope, uint64_t thread_id) {
    uint32_t id = (uint32_t)handle;
    uint32_t gen = (uint32_t)(handle >> 32);
    db_slot *slot;
    int rc;
    if (!ready || id == 0 || gen == 0 || id > lim.max_live_slots) {
        return KILN_DB_STALE;
    }
    slot = &slots[id];
    slot_lock(slot);
    rc = slot_check(slot, gen, kind, scope, thread_id);
    if (rc == KILN_DB_OK && slot->pins) {
        rc = KILN_DB_BUSY;
    } else if (rc == KILN_DB_OK) {
        slot->pins = 1;
    }
    slot_unlock(slot);
    return rc;
}

void *kiln_db_slot_acquire(uint64_t handle, int kind, uint64_t scope, uint64_t thread_id, int *err) {
    uint32_t id = (uint32_t)handle;
    uint32_t gen = (uint32_t)(handle >> 32);
    db_slot *slot;
    void *ptr = NULL;
    int rc;
    if (!ready || id == 0 || gen == 0 || id > lim.max_live_slots) {
        *err = KILN_DB_STALE;
        return NULL;
    }
    slot = &slots[id];
    slot_lock(slot);
    rc = slot_check(slot, gen, kind, scope, thread_id);
    if (rc == KILN_DB_OK && slot->pins) {
        rc = KILN_DB_BUSY;
    } else if (rc == KILN_DB_OK) {
        slot->pins = 1;
        ptr = slot->ptr;
    }
    slot_unlock(slot);
    *err = rc;
    return ptr;
}

void kiln_db_slot_release(uint64_t handle, int kind) {
    uint32_t id = (uint32_t)handle;
    uint32_t gen = (uint32_t)(handle >> 32);
    db_slot *slot;
    if (!ready || id == 0 || gen == 0 || id > lim.max_live_slots) {
        return;
    }
    slot = &slots[id];
    slot_lock(slot);
    if (slot->state == KILN_DB_SLOT_LIVE && slot->generation == gen && slot->kind == kind &&
        slot->pins == 1) {
        slot->pins = 0;
    }
    slot_unlock(slot);
}

int kiln_db_slot_unpin(uint64_t handle, int kind, uint64_t scope, uint64_t thread_id) {
    uint32_t id = (uint32_t)handle;
    uint32_t gen = (uint32_t)(handle >> 32);
    db_slot *slot;
    int rc;
    if (!ready || id == 0 || gen == 0 || id > lim.max_live_slots) {
        return KILN_DB_STALE;
    }
    slot = &slots[id];
    slot_lock(slot);
    rc = slot_check(slot, gen, kind, scope, thread_id);
    if (rc == KILN_DB_OK && slot->pins != 1) {
        rc = KILN_DB_OWNERSHIP;
    } else if (rc == KILN_DB_OK) {
        slot->pins = 0;
    }
    slot_unlock(slot);
    return rc;
}

static void slot_retire(db_slot *slot) {
    slot->ptr = NULL;
    slot->pins = 0;
    if (slot->generation == UINT32_MAX) {
        slot->state = KILN_DB_SLOT_RETIRED;
    } else {
        slot->generation++;
        slot->state = KILN_DB_SLOT_FREE;
    }
}

static int conn_idle(const db_slot *slot) {
    const kiln_db_conn *conn = slot->ptr;
    return conn && (!conn->active_op || pthread_equal(conn->owner, pthread_self()));
}

int kiln_db_slot_take_conn_idle(uint64_t handle, uint64_t scope, uint64_t thread_id, void **out) {
    uint32_t id = (uint32_t)handle;
    uint32_t gen = (uint32_t)(handle >> 32);
    db_slot *slot;
    int rc;
    if (!out) {
        return KILN_DB_ERR;
    }
    *out = NULL;
    if (!ready || id == 0 || gen == 0 || id > lim.max_live_slots) {
        return KILN_DB_STALE;
    }
    slot = &slots[id];
    pthread_mutex_lock(&mu);
    slot_lock(slot);
    rc = slot_check(slot, gen, KILN_DB_SLOT_CONN, scope, thread_id);
    if (rc == KILN_DB_OK && (slot->pins || !conn_idle(slot))) {
        rc = KILN_DB_BUSY;
    } else if (rc == KILN_DB_OK) {
        *out = slot->ptr;
        slot_retire(slot);
    }
    slot_unlock(slot);
    pthread_mutex_unlock(&mu);
    return rc;
}

int kiln_db_slot_take(uint64_t handle, int kind, uint64_t scope, uint64_t thread_id, void **out) {
    uint32_t id = (uint32_t)handle;
    uint32_t gen = (uint32_t)(handle >> 32);
    db_slot *slot;
    int rc;
    if (!out) {
        return KILN_DB_ERR;
    }
    *out = NULL;
    if (!ready || id == 0 || gen == 0 || id > lim.max_live_slots) {
        return KILN_DB_STALE;
    }
    slot = &slots[id];
    pthread_mutex_lock(&mu);
    slot_lock(slot);
    rc = slot_check(slot, gen, kind, scope, thread_id);
    if (rc == KILN_DB_OK && slot->pins) {
        rc = KILN_DB_BUSY;
    } else if (rc == KILN_DB_OK) {
        *out = slot->ptr;
        slot_retire(slot);
    }
    slot_unlock(slot);
    pthread_mutex_unlock(&mu);
    return rc;
}

uint64_t kiln_db_arena_open(uint64_t scope, uint64_t thread_id, int *err) {
    db_arena *arena;
    uint64_t handle;
    int local = KILN_DB_OK;
    if (!err) {
        err = &local;
    }
    arena = calloc(1, sizeof *arena);
    if (!arena) {
        *err = KILN_DB_CAPACITY;
        return 0;
    }
    arena->scope = scope;
    arena->thread_id = thread_id;
    handle = kiln_db_slot_put(KILN_DB_SLOT_ARENA, arena, scope, thread_id, err);
    if (!handle) {
        free(arena);
        return 0;
    }
    arena->generation = (uint32_t)(handle >> 32);
    return handle;
}

static int arena_block(const db_slot *slot, uint32_t arena_id, uint64_t scope, uint64_t thread_id) {
    const kiln_db_block *block = slot->ptr;
    return slot->state == KILN_DB_SLOT_LIVE && slot->kind == KILN_DB_SLOT_BLOCK && block &&
           block->arena_id == arena_id && block->scope == scope && block->thread_id == thread_id;
}

static uint32_t arena_lock_blocks(
    uint32_t id, uint64_t scope, uint64_t thread_id, uint32_t *ids, int *busy) {
    uint32_t i;
    uint32_t n = 0;
    *busy = 0;
    for (i = 1; i <= lim.max_live_slots; i++) {
        if (i == id || !arena_block(&slots[i], id, scope, thread_id)) {
            continue;
        }
        slot_lock(&slots[i]);
        ids[n++] = i;
        if (slots[i].pins) {
            *busy = 1;
        }
    }
    return n;
}

static void arena_unlock_blocks(const uint32_t *ids, uint32_t n) {
    uint32_t i;
    for (i = 0; i < n; i++) {
        slot_unlock(&slots[ids[i]]);
    }
}

int kiln_db_arena_close(uint64_t handle, uint64_t scope, uint64_t thread_id) {
    void **blocks;
    uint32_t *ids;
    db_slot *slot;
    uint32_t i;
    uint32_t n;
    uint32_t id = (uint32_t)handle;
    uint32_t gen = (uint32_t)(handle >> 32);
    void *arena = NULL;
    int rc;
    int busy;
    if (!ready || id == 0 || gen == 0 || id > lim.max_live_slots) {
        return KILN_DB_STALE;
    }
    blocks = calloc(lim.max_live_slots, sizeof *blocks);
    ids = calloc(lim.max_live_slots, sizeof *ids);
    if (!blocks || !ids) {
        free(blocks);
        free(ids);
        return KILN_DB_CAPACITY;
    }
    slot = &slots[id];
    pthread_mutex_lock(&mu);
    slot_lock(slot);
    rc = slot_check(slot, gen, KILN_DB_SLOT_ARENA, scope, thread_id);
    if (rc == KILN_DB_OK && slot->pins) {
        rc = KILN_DB_BUSY;
    }
    n = rc == KILN_DB_OK ? arena_lock_blocks(id, scope, thread_id, ids, &busy) : 0;
    if (rc == KILN_DB_OK && busy) {
        rc = KILN_DB_BUSY;
    }
    if (rc == KILN_DB_OK) {
        arena = slot->ptr;
        slot_retire(slot);
        for (i = 0; i < n; i++) {
            blocks[i] = slots[ids[i]].ptr;
            slot_retire(&slots[ids[i]]);
        }
    }
    arena_unlock_blocks(ids, n);
    slot_unlock(slot);
    pthread_mutex_unlock(&mu);
    if (rc == KILN_DB_OK) {
        for (i = 0; i < n; i++) {
            kiln_db_block_free(blocks[i]);
        }
        free(arena);
    }
    free(blocks);
    free(ids);
    return rc;
}
