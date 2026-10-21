#include "kiln_db.h"

#include <stdlib.h>
#include <string.h>

static int grow_exact(uint8_t **heap, uint32_t *cap, uint32_t need) {
    uint8_t *next;
    if (need <= *cap) {
        return KILN_DB_OK;
    }
    next = realloc(*heap, need);
    if (!next) {
        return KILN_DB_CAPACITY;
    }
    *heap = next;
    *cap = need;
    return KILN_DB_OK;
}

int kiln_db_gstr_put(uint8_t cell[KILN_DB_GSTR_CELL], uint8_t **heap, uint32_t *heap_len,
    uint32_t *heap_cap, const void *data, uint32_t len) {
    uint32_t offset;
    uint64_t offset64;
    uint8_t tmp[KILN_DB_GSTR_CELL];
    if (!cell || !heap || !heap_len || !heap_cap) {
        return KILN_DB_ERR;
    }
    if (len > 0 && !data) {
        return KILN_DB_ERR;
    }
    memset(tmp, 0, KILN_DB_GSTR_CELL);
    memcpy(tmp, &len, sizeof len);
    if (len <= KILN_DB_GSTR_INLINE) {
        if (len > 0) {
            memcpy(tmp + sizeof len, data, len);
        }
        memcpy(cell, tmp, KILN_DB_GSTR_CELL);
        return KILN_DB_OK;
    }
    if (*heap_len > UINT32_MAX - len) {
        return KILN_DB_CAPACITY;
    }
    offset = *heap_len;
    if (grow_exact(heap, heap_cap, offset + len) != KILN_DB_OK) {
        return KILN_DB_CAPACITY;
    }
    memcpy(*heap + offset, data, len);
    offset64 = offset;
    memcpy(tmp + 4, data, 4);
    memcpy(tmp + 8, &offset64, sizeof offset64);
    *heap_len = offset + len;
    memcpy(cell, tmp, KILN_DB_GSTR_CELL);
    return KILN_DB_OK;
}

int kiln_db_gstr_read(const uint8_t cell[KILN_DB_GSTR_CELL], const uint8_t *heap, uint32_t heap_len,
    const uint8_t **out, uint32_t *out_len) {
    uint32_t len = 0;
    uint64_t offset = 0;
    uint8_t prefix[4];
    if (!cell || !out || !out_len) {
        return KILN_DB_ERR;
    }
    memcpy(&len, cell, sizeof len);
    if (len <= KILN_DB_GSTR_INLINE) {
        *out = cell + 4;
        *out_len = len;
        return KILN_DB_OK;
    }
    if (!heap) {
        return KILN_DB_ERR;
    }
    memcpy(&offset, cell + 8, sizeof offset);
    if (offset > heap_len || len > heap_len - (uint32_t)offset) {
        return KILN_DB_ERR;
    }
    memcpy(prefix, cell + 4, 4);
    if (memcmp(prefix, heap + (uint32_t)offset, 4) != 0) {
        return KILN_DB_ERR;
    }
    *out = heap + (uint32_t)offset;
    *out_len = len;
    return KILN_DB_OK;
}
