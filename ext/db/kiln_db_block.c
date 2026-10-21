#include "kiln_db.h"

#include <limits.h>
#include <stdlib.h>
#include <string.h>

static int kind_ok(uint8_t kind) {
    return kind == KILN_DB_COL_I64 || kind == KILN_DB_COL_F64 || kind == KILN_DB_COL_BOOL ||
           kind == KILN_DB_COL_STR || kind == KILN_DB_COL_DICT;
}

static void set_null_bit(kiln_db_block *block, uint32_t col, uint32_t row, int is_null) {
    uint64_t bit = 1ull << (row % 64u);
    uint32_t word = row / 64u;
    if (is_null) {
        block->nulls[col][word] |= bit;
    } else {
        block->nulls[col][word] &= ~bit;
    }
}

static int null_bit(const kiln_db_block *block, uint32_t col, uint32_t row) {
    uint64_t bit = 1ull << (row % 64u);
    return (block->nulls[col][row / 64u] & bit) != 0;
}

void kiln_db_block_free(kiln_db_block *block) {
    uint32_t col;
    if (!block) {
        return;
    }
    if (block->data) {
        for (col = 0; col < block->ncols; col++) {
            free(block->data[col]);
        }
    }
    if (block->nulls) {
        for (col = 0; col < block->ncols; col++) {
            free(block->nulls[col]);
        }
    }
    if (block->heap) {
        for (col = 0; col < block->ncols; col++) {
            free(block->heap[col]);
        }
    }
    if (block->dict_bytes) {
        for (col = 0; col < block->ncols; col++) {
            free(block->dict_bytes[col]);
        }
    }
    free(block->kinds);
    free(block->data);
    free(block->nulls);
    free(block->heap);
    free(block->heap_len);
    free(block->heap_cap);
    free(block->dict_count);
    free(block->dict_width);
    free(block->dict_bytes);
    free(block->dict_lens);
    free(block->dict_cap);
    free(block);
}

static int mul_size(uint32_t a, uint32_t b, size_t *out) {
    if (a != 0 && (size_t)b > SIZE_MAX / a) {
        return KILN_DB_CAPACITY;
    }
    *out = (size_t)a * (size_t)b;
    return KILN_DB_OK;
}

uint64_t kiln_db_block_new(uint64_t arena, uint64_t scope, uint64_t thread_id, uint32_t rows,
    uint32_t cols, const uint8_t *kinds, int *err) {
    kiln_db_block *block;
    uint32_t col;
    uint32_t words;
    int local = KILN_DB_OK;
    int use_err = KILN_DB_OK;
    if (!err) {
        err = &local;
    }
    if (!kinds || rows == 0 || cols == 0) {
        *err = KILN_DB_ERR;
        return 0;
    }
    if (!kiln_db_slot_use(arena, KILN_DB_SLOT_ARENA, scope, thread_id, &use_err)) {
        *err = use_err;
        return 0;
    }
    for (col = 0; col < cols; col++) {
        if (!kind_ok(kinds[col])) {
            *err = KILN_DB_ERR;
            return 0;
        }
    }
    words = kiln_db_null_words(rows);
    block = calloc(1, sizeof *block);
    if (!block) {
        *err = KILN_DB_CAPACITY;
        return 0;
    }
    block->rows = rows;
    block->capacity = rows;
    block->ncols = cols;
    block->scope = scope;
    block->thread_id = thread_id;
    block->arena_id = (uint32_t)arena;
    block->kinds = malloc(cols);
    block->data = calloc(cols, sizeof *block->data);
    block->nulls = calloc(cols, sizeof *block->nulls);
    block->heap = calloc(cols, sizeof *block->heap);
    block->heap_len = calloc(cols, sizeof *block->heap_len);
    block->heap_cap = calloc(cols, sizeof *block->heap_cap);
    block->dict_count = calloc(cols, sizeof *block->dict_count);
    block->dict_width = malloc(cols);
    block->dict_bytes = calloc(cols, sizeof *block->dict_bytes);
    block->dict_lens = calloc(cols, sizeof *block->dict_lens);
    block->dict_cap = calloc(cols, sizeof *block->dict_cap);
    if (!block->kinds || !block->data || !block->nulls || !block->heap || !block->heap_len ||
        !block->heap_cap || !block->dict_count || !block->dict_width || !block->dict_bytes ||
        !block->dict_lens || !block->dict_cap) {
        kiln_db_block_free(block);
        *err = KILN_DB_CAPACITY;
        return 0;
    }
    memcpy(block->kinds, kinds, cols);
    for (col = 0; col < cols; col++) {
        size_t bytes = 0;
        uint32_t width = block->kinds[col] == KILN_DB_COL_STR
                             ? KILN_DB_GSTR_CELL
                             : (block->kinds[col] == KILN_DB_COL_DICT ? 1u : 8u);
        block->dict_width[col] = 1;
        if (mul_size(rows, width, &bytes) != KILN_DB_OK) {
            kiln_db_block_free(block);
            *err = KILN_DB_CAPACITY;
            return 0;
        }
        block->data[col] = calloc(1, bytes);
        block->nulls[col] = calloc(words, sizeof(uint64_t));
        if (!block->data[col] || !block->nulls[col]) {
            kiln_db_block_free(block);
            *err = KILN_DB_CAPACITY;
            return 0;
        }
        memset(block->nulls[col], 0xff, (size_t)(rows / 64u) * sizeof(uint64_t));
        if (rows % 64u) {
            block->nulls[col][rows / 64u] = (1ull << (rows % 64u)) - 1ull;
        }
    }
    {
        uint64_t handle = kiln_db_slot_put(KILN_DB_SLOT_BLOCK, block, scope, thread_id, err);
        if (!handle) {
            kiln_db_block_free(block);
            return 0;
        }
        block->generation = (uint32_t)(handle >> 32);
        return handle;
    }
}

static kiln_db_block *block_live(uint64_t handle, uint64_t scope, uint64_t thread_id, int *err) {
    return kiln_db_slot_use(handle, KILN_DB_SLOT_BLOCK, scope, thread_id, err);
}

kiln_db_block *kiln_db_block_get(uint64_t handle, uint64_t scope, uint64_t thread_id, int *err) {
    return block_live(handle, scope, thread_id, err);
}

static int cell_ok(const kiln_db_block *block, uint32_t col, uint32_t row, uint8_t kind) {
    return block && col < block->ncols && row < block->rows && block->kinds[col] == kind;
}

int kiln_db_block_set_i64(
    kiln_db_block *block, uint32_t col, uint32_t row, int is_null, int64_t value) {
    int64_t *vals;
    if (!cell_ok(block, col, row, KILN_DB_COL_I64)) {
        return KILN_DB_ERR;
    }
    vals = (int64_t *)block->data[col];
    if (is_null) {
        vals[row] = 0;
        set_null_bit(block, col, row, 1);
        return KILN_DB_OK;
    }
    vals[row] = value;
    set_null_bit(block, col, row, 0);
    return KILN_DB_OK;
}

int kiln_db_block_set_f64(
    kiln_db_block *block, uint32_t col, uint32_t row, int is_null, double value) {
    double *vals;
    if (!cell_ok(block, col, row, KILN_DB_COL_F64)) {
        return KILN_DB_ERR;
    }
    vals = (double *)block->data[col];
    if (is_null) {
        vals[row] = 0;
        set_null_bit(block, col, row, 1);
        return KILN_DB_OK;
    }
    vals[row] = value;
    set_null_bit(block, col, row, 0);
    return KILN_DB_OK;
}

int kiln_db_block_set_bool(
    kiln_db_block *block, uint32_t col, uint32_t row, int is_null, int value) {
    int64_t *vals;
    if (!cell_ok(block, col, row, KILN_DB_COL_BOOL)) {
        return KILN_DB_ERR;
    }
    vals = (int64_t *)block->data[col];
    if (is_null) {
        vals[row] = 0;
        set_null_bit(block, col, row, 1);
        return KILN_DB_OK;
    }
    vals[row] = value ? 1 : 0;
    set_null_bit(block, col, row, 0);
    return KILN_DB_OK;
}

int kiln_db_block_set_str(kiln_db_block *block, uint32_t col, uint32_t row, int is_null,
    const void *bytes, uint32_t len) {
    uint8_t *cell;
    int rc;
    if (!cell_ok(block, col, row, KILN_DB_COL_STR)) {
        return KILN_DB_ERR;
    }
    cell = block->data[col] + ((size_t)row * KILN_DB_GSTR_CELL);
    if (is_null) {
        memset(cell, 0, KILN_DB_GSTR_CELL);
        set_null_bit(block, col, row, 1);
        return KILN_DB_OK;
    }
    rc = kiln_db_gstr_put(
        cell, &block->heap[col], &block->heap_len[col], &block->heap_cap[col], bytes, len);
    if (rc != KILN_DB_OK) {
        return rc;
    }
    set_null_bit(block, col, row, 0);
    return KILN_DB_OK;
}

static int dict_find(
    const kiln_db_block *block, uint32_t col, const void *bytes, uint32_t len, uint32_t *code) {
    const uint8_t *p = (const uint8_t *)block->dict_bytes[col];
    uint32_t off = 0;
    uint32_t i;
    for (i = 0; i < block->dict_count[col]; i++) {
        uint32_t n = 0;
        if (off > block->dict_lens[col] || block->dict_lens[col] - off < 4u) {
            return KILN_DB_ERR;
        }
        memcpy(&n, p + off, 4);
        off += 4;
        if (n > block->dict_lens[col] - off) {
            return KILN_DB_ERR;
        }
        if (n == len && (n == 0 || memcmp(p + off, bytes, n) == 0)) {
            *code = i;
            return KILN_DB_OK;
        }
        off += n;
    }
    return KILN_DB_NOTFOUND;
}

static int dict_widen(kiln_db_block *block, uint32_t col) {
    uint16_t *next;
    uint8_t *old;
    uint32_t row;
    size_t bytes;
    if (block->dict_width[col] != 1) {
        return KILN_DB_OK;
    }
    if (mul_size(block->capacity, 2u, &bytes) != KILN_DB_OK) {
        return KILN_DB_CAPACITY;
    }
    if (bytes == 0) {
        return KILN_DB_CAPACITY;
    }
    next = malloc(bytes);
    if (!next) {
        return KILN_DB_CAPACITY;
    }
    old = block->data[col];
    for (row = 0; row < block->capacity; row++) {
        next[row] = old[row];
    }
    block->data[col] = (uint8_t *)next;
    block->dict_width[col] = 2;
    free(old);
    return KILN_DB_OK;
}

static int dict_append(kiln_db_block *block, uint32_t col, const void *bytes, uint32_t len) {
    uint32_t need;
    uint8_t *next;
    if (len > UINT32_MAX - 4u || block->dict_lens[col] > UINT32_MAX - (len + 4u)) {
        return KILN_DB_CAPACITY;
    }
    need = block->dict_lens[col] + len + 4u;
    if (need > block->dict_cap[col]) {
        next = realloc(block->dict_bytes[col], need);
        if (!next) {
            return KILN_DB_CAPACITY;
        }
        block->dict_bytes[col] = (char *)next;
        block->dict_cap[col] = need;
    }
    memcpy(block->dict_bytes[col] + block->dict_lens[col], &len, 4);
    if (len) {
        memcpy(block->dict_bytes[col] + block->dict_lens[col] + 4, bytes, len);
    }
    block->dict_lens[col] = need;
    return KILN_DB_OK;
}

static void dict_store(kiln_db_block *block, uint32_t col, uint32_t row, uint32_t code) {
    if (block->dict_width[col] == 1) {
        block->data[col][row] = (uint8_t)code;
    } else {
        ((uint16_t *)block->data[col])[row] = (uint16_t)code;
    }
}

int kiln_db_block_set_dict(kiln_db_block *block, uint32_t col, uint32_t row, int is_null,
    const void *bytes, uint32_t len) {
    uint32_t code = 0;
    int rc;
    if (!cell_ok(block, col, row, KILN_DB_COL_DICT)) {
        return KILN_DB_ERR;
    }
    if (is_null) {
        dict_store(block, col, row, 0);
        set_null_bit(block, col, row, 1);
        return KILN_DB_OK;
    }
    if (len && !bytes) {
        return KILN_DB_ERR;
    }
    rc = dict_find(block, col, bytes, len, &code);
    if (rc == KILN_DB_OK) {
        dict_store(block, col, row, code);
        set_null_bit(block, col, row, 0);
        return KILN_DB_OK;
    }
    if (rc != KILN_DB_NOTFOUND) {
        return rc;
    }
    if (block->dict_count[col] == 65536u) {
        return KILN_DB_CAPACITY;
    }
    if (block->dict_width[col] == 1 && block->dict_count[col] == 256u) {
        rc = dict_widen(block, col);
        if (rc != KILN_DB_OK) {
            return rc;
        }
    }
    rc = dict_append(block, col, bytes, len);
    if (rc != KILN_DB_OK) {
        return rc;
    }
    code = block->dict_count[col];
    dict_store(block, col, row, code);
    block->dict_count[col] = code + 1u;
    set_null_bit(block, col, row, 0);
    return KILN_DB_OK;
}

int kiln_db_block_rows(kiln_db_block *block, uint32_t rows) {
    if (!block || rows > block->capacity) {
        return KILN_DB_ERR;
    }
    block->rows = rows;
    return KILN_DB_OK;
}

static kiln_db_block *need_block(uint64_t handle, uint64_t scope, uint64_t thread_id, int *err) {
    int local = KILN_DB_OK;
    kiln_db_block *block = block_live(handle, scope, thread_id, err ? err : &local);
    return block;
}

int kiln_db_copy_i64(
    uint64_t handle, uint64_t scope, uint64_t thread_id, uint32_t col, int64_t *dst, uint32_t n) {
    kiln_db_block *block;
    int err = KILN_DB_OK;
    uint32_t row;
    int64_t *vals;
    block = need_block(handle, scope, thread_id, &err);
    if (!block) {
        return err;
    }
    if (!dst || col >= block->ncols || n > block->rows) {
        return KILN_DB_ERR;
    }
    if (block->kinds[col] != KILN_DB_COL_I64 && block->kinds[col] != KILN_DB_COL_BOOL) {
        return KILN_DB_ERR;
    }
    vals = (int64_t *)block->data[col];
    for (row = 0; row < n; row++) {
        dst[row] = null_bit(block, col, row) ? 0 : vals[row];
    }
    return KILN_DB_OK;
}

int kiln_db_copy_f64(
    uint64_t handle, uint64_t scope, uint64_t thread_id, uint32_t col, double *dst, uint32_t n) {
    kiln_db_block *block;
    int err = KILN_DB_OK;
    uint32_t row;
    double *vals;
    block = need_block(handle, scope, thread_id, &err);
    if (!block) {
        return err;
    }
    if (!dst || col >= block->ncols || n > block->rows || block->kinds[col] != KILN_DB_COL_F64) {
        return KILN_DB_ERR;
    }
    vals = (double *)block->data[col];
    for (row = 0; row < n; row++) {
        dst[row] = null_bit(block, col, row) ? 0 : vals[row];
    }
    return KILN_DB_OK;
}

int kiln_db_copy_nulls(uint64_t handle, uint64_t scope, uint64_t thread_id, uint32_t col,
    int64_t *dst, uint32_t words) {
    kiln_db_block *block;
    int err = KILN_DB_OK;
    uint32_t need;
    uint32_t i;
    block = need_block(handle, scope, thread_id, &err);
    if (!block) {
        return err;
    }
    need = kiln_db_null_words(block->rows);
    if (!dst || col >= block->ncols || words < need) {
        return KILN_DB_ERR;
    }
    for (i = 0; i < need; i++) {
        dst[i] = (int64_t)block->nulls[col][i];
    }
    return KILN_DB_OK;
}

static int dict_code_read(const kiln_db_block *block, uint32_t col, uint32_t code,
    const uint8_t **out, uint32_t *out_len) {
    const uint8_t *p = (const uint8_t *)block->dict_bytes[col];
    uint32_t off = 0;
    uint32_t i;
    if (code >= block->dict_count[col]) {
        return KILN_DB_ERR;
    }
    for (i = 0; i <= code; i++) {
        uint32_t n = 0;
        if (off > block->dict_lens[col] || block->dict_lens[col] - off < 4u) {
            return KILN_DB_ERR;
        }
        memcpy(&n, p + off, 4);
        off += 4;
        if (n > block->dict_lens[col] - off) {
            return KILN_DB_ERR;
        }
        if (i == code) {
            *out = p + off;
            *out_len = n;
            return KILN_DB_OK;
        }
        off += n;
    }
    return KILN_DB_ERR;
}

int kiln_db_copy_strs(uint64_t handle, uint64_t scope, uint64_t thread_id, uint32_t col, char *dst,
    size_t dst_cap, size_t *nbytes, int64_t *offsets, uint32_t n) {
    kiln_db_block *block;
    int err = KILN_DB_OK;
    uint32_t row;
    size_t need = 0;
    size_t at = 0;
    block = need_block(handle, scope, thread_id, &err);
    if (!block) {
        return err;
    }
    if (!nbytes || !offsets || col >= block->ncols || n > block->rows) {
        return KILN_DB_ERR;
    }
    if (block->kinds[col] != KILN_DB_COL_STR && block->kinds[col] != KILN_DB_COL_DICT) {
        return KILN_DB_ERR;
    }
    for (row = 0; row < n; row++) {
        const uint8_t *bytes = NULL;
        uint32_t len = 0;
        if (null_bit(block, col, row)) {
            continue;
        }
        if (block->kinds[col] == KILN_DB_COL_STR) {
            const uint8_t *cell = block->data[col] + ((size_t)row * KILN_DB_GSTR_CELL);
            if (kiln_db_gstr_read(cell, block->heap[col], block->heap_len[col], &bytes, &len) !=
                KILN_DB_OK) {
                return KILN_DB_ERR;
            }
        } else {
            uint32_t code = block->dict_width[col] == 1 ? block->data[col][row]
                                                        : ((const uint16_t *)block->data[col])[row];
            if (dict_code_read(block, col, code, &bytes, &len) != KILN_DB_OK) {
                return KILN_DB_ERR;
            }
        }
        if (need > SIZE_MAX - 4u - len) {
            return KILN_DB_CAPACITY;
        }
        need += 4u + len;
        (void)bytes;
    }
    *nbytes = need;
    if (!dst || dst_cap < need) {
        return KILN_DB_CAPACITY;
    }
    for (row = 0; row < n; row++) {
        const uint8_t *bytes = NULL;
        uint32_t len = 0;
        if (null_bit(block, col, row)) {
            offsets[row] = -1;
            continue;
        }
        if (block->kinds[col] == KILN_DB_COL_STR) {
            const uint8_t *cell = block->data[col] + ((size_t)row * KILN_DB_GSTR_CELL);
            kiln_db_gstr_read(cell, block->heap[col], block->heap_len[col], &bytes, &len);
        } else {
            uint32_t code = block->dict_width[col] == 1 ? block->data[col][row]
                                                        : ((const uint16_t *)block->data[col])[row];
            dict_code_read(block, col, code, &bytes, &len);
        }
        memcpy(dst + at, &len, 4);
        if (len) {
            memcpy(dst + at + 4, bytes, len);
        }
        offsets[row] = (int64_t)at;
        at += 4u + len;
    }
    return KILN_DB_OK;
}

int kiln_db_block_open(uint64_t scope, uint64_t thread_id, uint32_t rows, uint32_t cols,
    const int64_t *kinds, int n, int64_t *out, int out_n) {
    uint8_t local[8];
    uint32_t col;
    int err = KILN_DB_OK;
    uint64_t arena;
    uint64_t handle;
    if (!out || out_n < 2 || !kinds || rows == 0 || cols == 0 || cols > 8 || n < (int)cols) {
        return KILN_DB_ERR;
    }
    for (col = 0; col < cols; col++) {
        if (kinds[col] < 1 || kinds[col] > 5) {
            return KILN_DB_ERR;
        }
        local[col] = (uint8_t)kinds[col];
    }
    arena = kiln_db_arena_open(scope, thread_id, &err);
    if (!arena) {
        return err;
    }
    handle = kiln_db_block_new(arena, scope, thread_id, rows, cols, local, &err);
    if (!handle) {
        kiln_db_arena_close(arena, scope, thread_id);
        return err;
    }
    out[0] = (int64_t)handle;
    out[1] = (int64_t)arena;
    return KILN_DB_OK;
}

int kiln_db_block_close(uint64_t block, uint64_t arena, uint64_t scope, uint64_t thread_id) {
    void *ptr = NULL;
    int rc = kiln_db_slot_take(block, KILN_DB_SLOT_BLOCK, scope, thread_id, &ptr);
    if (rc == KILN_DB_OK) {
        kiln_db_block_free(ptr);
    }
    kiln_db_arena_close(arena, scope, thread_id);
    return rc;
}

int kiln_db_copy_null_rows(
    uint64_t handle, uint64_t scope, uint64_t thread_id, uint32_t col, int64_t *dst, uint32_t n) {
    kiln_db_block *block;
    int err = KILN_DB_OK;
    uint32_t row;
    block = need_block(handle, scope, thread_id, &err);
    if (!block) {
        return err;
    }
    if (!dst || col >= block->ncols || n > block->rows) {
        return KILN_DB_ERR;
    }
    for (row = 0; row < n; row++) {
        dst[row] = null_bit(block, col, row) ? 1 : 0;
    }
    return KILN_DB_OK;
}

static __thread char *text_buf;
static __thread size_t text_cap;

static char *text_fit(size_t need) {
    char *next;
    if (need <= text_cap && text_buf) {
        return text_buf;
    }
    if (need == 0) {
        return text_buf;
    }
    next = realloc(text_buf, need);
    if (!next) {
        return NULL;
    }
    text_buf = next;
    text_cap = need;
    return text_buf;
}

static int text_cell(
    const kiln_db_block *block, uint32_t col, uint32_t row, const uint8_t **bytes, uint32_t *len) {
    if (null_bit(block, col, row)) {
        *bytes = NULL;
        *len = 0;
        return KILN_DB_OK;
    }
    if (block->kinds[col] == KILN_DB_COL_STR) {
        const uint8_t *cell = block->data[col] + ((size_t)row * KILN_DB_GSTR_CELL);
        return kiln_db_gstr_read(cell, block->heap[col], block->heap_len[col], bytes, len);
    }
    if (block->kinds[col] == KILN_DB_COL_DICT) {
        uint32_t code = block->dict_width[col] == 1 ? block->data[col][row]
                                                    : ((const uint16_t *)block->data[col])[row];
        return dict_code_read(block, col, code, bytes, len);
    }
    return KILN_DB_ERR;
}

const char *kiln_db_block_text(uint64_t handle, uint64_t scope, uint64_t thread_id, uint32_t col,
    int64_t *offs, int offs_n, int64_t *lens, int lens_n, int64_t *meta, int meta_n) {
    static __thread char empty[1];
    kiln_db_block *block;
    int err = KILN_DB_OK;
    uint32_t row;
    size_t need = 0;
    size_t at = 0;
    char *dst;
    empty[0] = 0;
    sp_ffi_bin_len = 0;
    if (meta && meta_n > 0) {
        meta[0] = -1;
    }
    block = need_block(handle, scope, thread_id, &err);
    if (!block || !offs || !lens || !meta || meta_n < 2 || col >= block->ncols ||
        offs_n < (int)block->rows || lens_n < (int)block->rows) {
        return empty;
    }
    if (block->kinds[col] != KILN_DB_COL_STR && block->kinds[col] != KILN_DB_COL_DICT) {
        return empty;
    }
    for (row = 0; row < block->rows; row++) {
        const uint8_t *bytes = NULL;
        uint32_t len = 0;
        if (text_cell(block, col, row, &bytes, &len) != KILN_DB_OK) {
            return empty;
        }
        if (!bytes) {
            continue;
        }
        if (need > (size_t)INT_MAX || (size_t)len > (size_t)INT_MAX - need) {
            return empty;
        }
        need += len;
        (void)bytes;
    }
    dst = text_fit(need == 0 ? 1 : need);
    if (!dst) {
        return empty;
    }
    for (row = 0; row < block->rows; row++) {
        const uint8_t *bytes = NULL;
        uint32_t len = 0;
        if (text_cell(block, col, row, &bytes, &len) != KILN_DB_OK) {
            return empty;
        }
        if (!bytes) {
            offs[row] = -1;
            lens[row] = 0;
            continue;
        }
        if (len) {
            memcpy(dst + at, bytes, len);
        }
        offs[row] = (int64_t)at;
        lens[row] = (int64_t)len;
        at += len;
    }
    meta[0] = (int64_t)at;
    meta[1] = (int64_t)block->rows;
    sp_ffi_bin_len = (int)at;
    return dst;
}
