#include "kiln_db.h"

#include <string.h>

static int parse_i64(const char *text, int length, int64_t *out) {
    char buf[40];
    int64_t words[2];
    uint64_t bits;
    if (!text || length <= 0 || length >= (int)sizeof buf) {
        return KILN_DB_ERR;
    }
    memcpy(buf, text, (size_t)length);
    buf[length] = 0;
    if (kiln_db_i64_parse(buf, words, 2) != KILN_DB_OK) {
        return KILN_DB_ERR;
    }
    if (words[0] < (-2147483647 - 1) || words[0] > 2147483647 || words[1] < 0 ||
        words[1] > 4294967295LL) {
        return KILN_DB_ERR;
    }
    bits = ((uint64_t)(uint32_t)(int32_t)words[0] << 32) | (uint32_t)words[1];
    *out = (int64_t)bits;
    return KILN_DB_OK;
}

static int store_cell(kiln_db_block *block, uint32_t col, uint32_t row, int is_null,
    const char *view, uint32_t length) {
    uint8_t kind = block->kinds[col];
    int64_t value = 0;
    if (kind == KILN_DB_COL_I64) {
        if (!is_null && parse_i64(view, (int)length, &value) != KILN_DB_OK) {
            return KILN_DB_ERR;
        }
        return kiln_db_block_set_i64(block, col, row, is_null, value);
    }
    if (kind == KILN_DB_COL_STR) {
        return kiln_db_block_set_str(block, col, row, is_null, view, length);
    }
    if (kind == KILN_DB_COL_DICT) {
        return kiln_db_block_set_dict(block, col, row, is_null, view, length);
    }
    return KILN_DB_ERR;
}

int kiln_db_block_import(uint64_t conn, uint64_t block_handle, uint64_t scope, uint64_t thread_id,
    uint32_t dest_row, int64_t *out, int out_n) {
    kiln_db_block *block;
    int err = KILN_DB_OK;
    int64_t meta[5];
    int64_t cell[2];
    uint32_t rows;
    uint32_t cols;
    uint32_t row;
    uint32_t col;
    int64_t copied = 0;
    if (!out || out_n < 2) {
        return KILN_DB_ERR;
    }
    out[0] = 0;
    out[1] = 0;
    block = kiln_db_block_get(block_handle, scope, thread_id, &err);
    if (!block) {
        return err;
    }
    if (kiln_db_result_meta(conn, scope, thread_id, meta, 5) != KILN_DB_OK) {
        return KILN_DB_ERR;
    }
    cols = (uint32_t)meta[0];
    rows = (uint32_t)meta[1];
    if (cols != block->ncols || meta[0] < 0 || meta[1] < 0) {
        return KILN_DB_ERR;
    }
    if (dest_row > block->rows || rows > block->rows - dest_row) {
        return KILN_DB_CAPACITY;
    }
    for (row = 0; row < rows; row++) {
        for (col = 0; col < cols; col++) {
            const char *view = kiln_db_result_bytes(conn, scope, thread_id, row, col, cell, 2);
            int is_null = (int)cell[0];
            int length = (int)cell[1];
            int rc;
            if (length < 0) {
                return KILN_DB_ERR;
            }
            copied += length;
            rc = store_cell(block, col, dest_row + row, is_null, view, (uint32_t)length);
            if (rc != KILN_DB_OK) {
                return rc;
            }
        }
    }
    out[0] = (int64_t)rows;
    out[1] = copied;
    return KILN_DB_OK;
}
