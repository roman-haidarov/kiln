#include "kiln_db.h"

#include <pthread.h>
#include <stdlib.h>
#include <string.h>

#define ID_U64  1
#define ID_UUID 2

typedef struct {
    int state;
    int kind;
    uint32_t generation;
    uint64_t *u64s;
    uint8_t *uuids;
    uint32_t n;
    uint32_t cap;
} db_idset;

static pthread_mutex_t id_mu = PTHREAD_MUTEX_INITIALIZER;
static db_idset *id_sets;
static uint32_t id_cap;

static int ensure_sets(void) {
    const kiln_db_limits *limits = kiln_db_limits_get();
    if (!limits) {
        return KILN_DB_CONFIG;
    }
    if (id_sets) {
        return KILN_DB_OK;
    }
    id_sets = calloc((size_t)limits->max_live_slots + 1u, sizeof *id_sets);
    if (!id_sets) {
        return KILN_DB_CAPACITY;
    }
    id_cap = limits->max_live_slots;
    return KILN_DB_OK;
}

static db_idset *id_use(uint64_t handle, int kind, int *err) {
    uint32_t id = (uint32_t)handle;
    uint32_t gen = (uint32_t)(handle >> 32);
    if (id == 0 || gen == 0 || id > id_cap || !id_sets) {
        *err = KILN_DB_STALE;
        return NULL;
    }
    if (id_sets[id].state != KILN_DB_SLOT_LIVE || id_sets[id].generation != gen ||
        id_sets[id].kind != kind) {
        *err = KILN_DB_STALE;
        return NULL;
    }
    *err = KILN_DB_OK;
    return &id_sets[id];
}

int kiln_db_idset_new(int kind, uint64_t *out_handle) {
    uint32_t i;
    int rc;
    if (!out_handle || (kind != ID_U64 && kind != ID_UUID)) {
        return KILN_DB_ERR;
    }
    pthread_mutex_lock(&id_mu);
    rc = ensure_sets();
    if (rc != KILN_DB_OK) {
        pthread_mutex_unlock(&id_mu);
        return rc;
    }
    for (i = 1; i <= id_cap; i++) {
        if (id_sets[i].state != KILN_DB_SLOT_FREE) {
            continue;
        }
        if (id_sets[i].generation == 0) {
            id_sets[i].generation = 1;
        }
        id_sets[i].state = KILN_DB_SLOT_LIVE;
        id_sets[i].kind = kind;
        id_sets[i].n = 0;
        id_sets[i].cap = 0;
        id_sets[i].u64s = NULL;
        id_sets[i].uuids = NULL;
        *out_handle = ((uint64_t)id_sets[i].generation << 32) | (uint64_t)i;
        pthread_mutex_unlock(&id_mu);
        return KILN_DB_OK;
    }
    pthread_mutex_unlock(&id_mu);
    return KILN_DB_CAPACITY;
}

static int grow_u64(db_idset *set) {
    uint32_t cap = set->cap == 0 ? 1u : set->cap + 1u;
    uint64_t *next;
    if (cap < set->cap) {
        return KILN_DB_CAPACITY;
    }
    next = realloc(set->u64s, (size_t)cap * sizeof *next);
    if (!next) {
        return KILN_DB_CAPACITY;
    }
    set->u64s = next;
    set->cap = cap;
    return KILN_DB_OK;
}

int kiln_db_idset_add_u64(uint64_t handle, uint64_t value) {
    db_idset *set;
    int err = KILN_DB_OK;
    uint32_t lo;
    uint32_t hi;
    pthread_mutex_lock(&id_mu);
    set = id_use(handle, ID_U64, &err);
    if (!set) {
        pthread_mutex_unlock(&id_mu);
        return err;
    }
    lo = 0;
    hi = set->n;
    while (lo < hi) {
        uint32_t mid = lo + ((hi - lo) / 2u);
        if (set->u64s[mid] == value) {
            pthread_mutex_unlock(&id_mu);
            return KILN_DB_OK;
        }
        if (set->u64s[mid] < value) {
            lo = mid + 1u;
        } else {
            hi = mid;
        }
    }
    if (set->n == set->cap) {
        err = grow_u64(set);
        if (err != KILN_DB_OK) {
            pthread_mutex_unlock(&id_mu);
            return err;
        }
    }
    memmove(set->u64s + lo + 1u, set->u64s + lo, (size_t)(set->n - lo) * sizeof *set->u64s);
    set->u64s[lo] = value;
    set->n++;
    pthread_mutex_unlock(&id_mu);
    return KILN_DB_OK;
}

int kiln_db_idset_has_u64(uint64_t handle, uint64_t value) {
    db_idset *set;
    int err = KILN_DB_OK;
    uint32_t lo;
    uint32_t hi;
    pthread_mutex_lock(&id_mu);
    set = id_use(handle, ID_U64, &err);
    if (!set) {
        pthread_mutex_unlock(&id_mu);
        return err;
    }
    lo = 0;
    hi = set->n;
    while (lo < hi) {
        uint32_t mid = lo + ((hi - lo) / 2u);
        if (set->u64s[mid] == value) {
            pthread_mutex_unlock(&id_mu);
            return 1;
        }
        if (set->u64s[mid] < value) {
            lo = mid + 1u;
        } else {
            hi = mid;
        }
    }
    pthread_mutex_unlock(&id_mu);
    return 0;
}

static int grow_uuid(db_idset *set) {
    uint32_t cap = set->cap == 0 ? 1u : set->cap + 1u;
    uint8_t *next;
    if (cap < set->cap || cap > UINT32_MAX / 16u) {
        return KILN_DB_CAPACITY;
    }
    next = realloc(set->uuids, (size_t)cap * 16u);
    if (!next) {
        return KILN_DB_CAPACITY;
    }
    set->uuids = next;
    set->cap = cap;
    return KILN_DB_OK;
}

int kiln_db_idset_add_uuid(uint64_t handle, const uint8_t key[16]) {
    db_idset *set;
    int err = KILN_DB_OK;
    uint32_t lo;
    uint32_t hi;
    if (!key) {
        return KILN_DB_ERR;
    }
    pthread_mutex_lock(&id_mu);
    set = id_use(handle, ID_UUID, &err);
    if (!set) {
        pthread_mutex_unlock(&id_mu);
        return err;
    }
    lo = 0;
    hi = set->n;
    while (lo < hi) {
        uint32_t mid = lo + ((hi - lo) / 2u);
        int cmp = memcmp(set->uuids + ((size_t)mid * 16u), key, 16);
        if (cmp == 0) {
            pthread_mutex_unlock(&id_mu);
            return KILN_DB_OK;
        }
        if (cmp < 0) {
            lo = mid + 1u;
        } else {
            hi = mid;
        }
    }
    if (set->n == set->cap) {
        err = grow_uuid(set);
        if (err != KILN_DB_OK) {
            pthread_mutex_unlock(&id_mu);
            return err;
        }
    }
    memmove(set->uuids + ((size_t)lo + 1u) * 16u, set->uuids + (size_t)lo * 16u,
        (size_t)(set->n - lo) * 16u);
    memcpy(set->uuids + (size_t)lo * 16u, key, 16);
    set->n++;
    pthread_mutex_unlock(&id_mu);
    return KILN_DB_OK;
}

int kiln_db_idset_has_uuid(uint64_t handle, const uint8_t key[16]) {
    db_idset *set;
    int err = KILN_DB_OK;
    uint32_t lo;
    uint32_t hi;
    if (!key) {
        return KILN_DB_CONFIG;
    }
    pthread_mutex_lock(&id_mu);
    set = id_use(handle, ID_UUID, &err);
    if (!set) {
        pthread_mutex_unlock(&id_mu);
        return err;
    }
    lo = 0;
    hi = set->n;
    while (lo < hi) {
        uint32_t mid = lo + ((hi - lo) / 2u);
        int cmp = memcmp(set->uuids + ((size_t)mid * 16u), key, 16);
        if (cmp == 0) {
            pthread_mutex_unlock(&id_mu);
            return 1;
        }
        if (cmp < 0) {
            lo = mid + 1u;
        } else {
            hi = mid;
        }
    }
    pthread_mutex_unlock(&id_mu);
    return 0;
}

int kiln_db_idset_free(uint64_t handle) {
    uint32_t id = (uint32_t)handle;
    uint32_t gen = (uint32_t)(handle >> 32);
    pthread_mutex_lock(&id_mu);
    if (!id_sets || id == 0 || gen == 0 || id > id_cap || id_sets[id].state != KILN_DB_SLOT_LIVE ||
        id_sets[id].generation != gen) {
        pthread_mutex_unlock(&id_mu);
        return KILN_DB_STALE;
    }
    free(id_sets[id].u64s);
    free(id_sets[id].uuids);
    id_sets[id].u64s = NULL;
    id_sets[id].uuids = NULL;
    id_sets[id].n = 0;
    id_sets[id].cap = 0;
    if (id_sets[id].generation == UINT32_MAX) {
        id_sets[id].state = KILN_DB_SLOT_RETIRED;
    } else {
        id_sets[id].generation++;
        id_sets[id].state = KILN_DB_SLOT_FREE;
    }
    pthread_mutex_unlock(&id_mu);
    return KILN_DB_OK;
}
