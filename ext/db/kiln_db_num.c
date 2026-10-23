#include "kiln_db.h"

#include <stdio.h>
#include <string.h>

static __thread char num_text[40];

static int split_i64(int64_t value, int64_t *hi, int64_t *lo) {
    uint64_t bits = (uint64_t)value;
    uint32_t hi32 = (uint32_t)(bits >> 32);
    *lo = (int64_t)(uint32_t)bits;
    *hi = (int64_t)(int32_t)hi32;
    return 0;
}

static int join_i64(int64_t hi, int64_t lo, int64_t *out) {
    uint64_t bits;
    if (hi < (-2147483647 - 1) || hi > 2147483647) {
        return -1;
    }
    if (lo < 0 || lo > 4294967295LL) {
        return -1;
    }
    bits = ((uint64_t)(uint32_t)(int32_t)hi << 32) | (uint32_t)lo;
    *out = (int64_t)bits;
    return 0;
}

static int join_u64(int64_t hi, int64_t lo, uint64_t *out) {
    if (hi < 0 || hi > 4294967295LL || lo < 0 || lo > 4294967295LL) {
        return -1;
    }
    *out = ((uint64_t)(uint32_t)hi << 32) | (uint32_t)lo;
    return 0;
}

static void split_u64(uint64_t value, int64_t *hi, int64_t *lo) {
    *lo = (int64_t)(uint32_t)value;
    *hi = (int64_t)(uint32_t)(value >> 32);
}

static int write_pair(int64_t *out, int n, int64_t hi, int64_t lo) {
    if (!out || n < 2) {
        return KILN_DB_CONFIG;
    }
    out[0] = hi;
    out[1] = lo;
    return KILN_DB_OK;
}

static int scan_digits(const char *text, int *index, int *overflow, uint64_t *mag) {
    int any = 0;
    uint64_t value = 0;
    *overflow = 0;
    while (text[*index] >= '0' && text[*index] <= '9') {
        unsigned digit = (unsigned)(text[*index] - '0');
        if (!*overflow) {
            if (value > (UINT64_MAX - digit) / 10ull) {
                *overflow = 1;
            } else {
                value = (value * 10ull) + digit;
            }
        }
        any = 1;
        (*index)++;
    }
    *mag = value;
    return any;
}

static int parse_signed(const char *text, int *negative, int *overflow, uint64_t *mag) {
    int index = 0;
    if (!text || !text[0]) {
        return KILN_DB_CONFIG;
    }
    *negative = 0;
    if (text[0] == '+' || text[0] == '-') {
        *negative = text[0] == '-';
        index = 1;
    }
    if (!scan_digits(text, &index, overflow, mag) || text[index] != 0) {
        return KILN_DB_CONFIG;
    }
    return KILN_DB_OK;
}

int kiln_db_i64_parse(const char *text, int64_t *out, int n) {
    int negative = 0;
    int overflow = 0;
    uint64_t mag = 0;
    int rc;
    int64_t value;
    int64_t hi;
    int64_t lo;
    rc = parse_signed(text, &negative, &overflow, &mag);
    if (rc != KILN_DB_OK) {
        return rc;
    }
    if (overflow) {
        return KILN_DB_ERR;
    }
    if (negative) {
        if (mag > 9223372036854775808ull) {
            return KILN_DB_ERR;
        }
        if (mag == 9223372036854775808ull) {
            value = (int64_t)(-9223372036854775807LL - 1);
        } else {
            value = -(int64_t)mag;
        }
    } else {
        if (mag > 9223372036854775807ull) {
            return KILN_DB_ERR;
        }
        value = (int64_t)mag;
    }
    split_i64(value, &hi, &lo);
    return write_pair(out, n, hi, lo);
}

int kiln_db_u64_parse(const char *text, int64_t *out, int n) {
    int index = 0;
    int overflow = 0;
    uint64_t mag = 0;
    int64_t hi;
    int64_t lo;
    if (!text || !text[0] || text[0] == '+' || text[0] == '-') {
        return KILN_DB_CONFIG;
    }
    if (!scan_digits(text, &index, &overflow, &mag) || text[index] != 0) {
        return KILN_DB_CONFIG;
    }
    if (overflow) {
        return KILN_DB_ERR;
    }
    split_u64(mag, &hi, &lo);
    return write_pair(out, n, hi, lo);
}

static int store_i64(int64_t value, int64_t *out, int n) {
    int64_t hi;
    int64_t lo;
    split_i64(value, &hi, &lo);
    return write_pair(out, n, hi, lo);
}

static int store_u64(uint64_t value, int64_t *out, int n) {
    int64_t hi;
    int64_t lo;
    split_u64(value, &hi, &lo);
    return write_pair(out, n, hi, lo);
}

int kiln_db_i64_apply(int op, int64_t ah, int64_t al, int64_t bh, int64_t bl, int64_t *out, int n) {
    int64_t a;
    int64_t b;
    int64_t result;
    int64_t remain;
    if (join_i64(ah, al, &a) != 0 || join_i64(bh, bl, &b) != 0) {
        return KILN_DB_ERR;
    }
    if (op == KILN_DB_NUM_ADD) {
        if (__builtin_add_overflow(a, b, &result)) {
            return KILN_DB_ERR;
        }
        return store_i64(result, out, n);
    }
    if (op == KILN_DB_NUM_SUB) {
        if (__builtin_sub_overflow(a, b, &result)) {
            return KILN_DB_ERR;
        }
        return store_i64(result, out, n);
    }
    if (op == KILN_DB_NUM_MUL) {
        if (__builtin_mul_overflow(a, b, &result)) {
            return KILN_DB_ERR;
        }
        return store_i64(result, out, n);
    }
    if (op == KILN_DB_NUM_NEG) {
        if (a == (int64_t)(-9223372036854775807LL - 1)) {
            return KILN_DB_ERR;
        }
        return store_i64(-a, out, n);
    }
    if (op != KILN_DB_NUM_DIV && op != KILN_DB_NUM_MOD) {
        return KILN_DB_CONFIG;
    }
    if (b == 0) {
        return KILN_DB_ERR;
    }
    if (a == (int64_t)(-9223372036854775807LL - 1) && b == -1) {
        return KILN_DB_ERR;
    }
    result = a / b;
    remain = a % b;
    if (op == KILN_DB_NUM_MOD) {
        return store_i64(remain, out, n);
    }
    if (store_i64(result, out, n) != KILN_DB_OK) {
        return KILN_DB_CONFIG;
    }
    if (n >= 4) {
        int64_t hi;
        int64_t lo;
        split_i64(remain, &hi, &lo);
        out[2] = hi;
        out[3] = lo;
    }
    return KILN_DB_OK;
}

int kiln_db_u64_apply(int op, int64_t ah, int64_t al, int64_t bh, int64_t bl, int64_t *out, int n) {
    uint64_t a;
    uint64_t b;
    uint64_t result;
    uint64_t remain;
    if (join_u64(ah, al, &a) != 0 || join_u64(bh, bl, &b) != 0) {
        return KILN_DB_ERR;
    }
    if (op == KILN_DB_NUM_ADD) {
        if (__builtin_add_overflow(a, b, &result)) {
            return KILN_DB_ERR;
        }
        return store_u64(result, out, n);
    }
    if (op == KILN_DB_NUM_SUB) {
        if (a < b) {
            return KILN_DB_ERR;
        }
        return store_u64(a - b, out, n);
    }
    if (op == KILN_DB_NUM_MUL) {
        if (__builtin_mul_overflow(a, b, &result)) {
            return KILN_DB_ERR;
        }
        return store_u64(result, out, n);
    }
    if (op == KILN_DB_NUM_NEG) {
        if (a != 0) {
            return KILN_DB_ERR;
        }
        return store_u64(0, out, n);
    }
    if (op != KILN_DB_NUM_DIV && op != KILN_DB_NUM_MOD) {
        return KILN_DB_CONFIG;
    }
    if (b == 0) {
        return KILN_DB_ERR;
    }
    result = a / b;
    remain = a % b;
    if (op == KILN_DB_NUM_MOD) {
        return store_u64(remain, out, n);
    }
    if (store_u64(result, out, n) != KILN_DB_OK) {
        return KILN_DB_CONFIG;
    }
    if (n >= 4) {
        int64_t hi;
        int64_t lo;
        split_u64(remain, &hi, &lo);
        out[2] = hi;
        out[3] = lo;
    }
    return KILN_DB_OK;
}

int kiln_db_i64_cmp_text(int64_t hi, int64_t lo, const char *text, int64_t *out, int n) {
    int64_t value;
    uint64_t left_mag;
    int left_neg;
    int negative = 0;
    int overflow = 0;
    uint64_t mag = 0;
    int too_wide;
    int rc;
    if (!out || n < 1) {
        return KILN_DB_CONFIG;
    }
    if (join_i64(hi, lo, &value) != 0) {
        return KILN_DB_ERR;
    }
    rc = parse_signed(text, &negative, &overflow, &mag);
    if (rc != KILN_DB_OK) {
        return rc;
    }
    left_neg = value < 0;
    if (left_neg) {
        left_mag = (uint64_t)(-(value + 1)) + 1ull;
    } else {
        left_mag = (uint64_t)value;
    }
    too_wide = overflow || (negative && mag > 9223372036854775808ull) ||
               (!negative && mag > 9223372036854775807ull);
    if (too_wide) {
        out[0] = negative ? 1 : -1;
        return KILN_DB_OK;
    }
    if (left_mag == 0 && mag == 0) {
        out[0] = 0;
        return KILN_DB_OK;
    }
    if (left_neg != negative) {
        out[0] = left_neg ? -1 : 1;
        return KILN_DB_OK;
    }
    if (left_mag == mag) {
        out[0] = 0;
    } else if (left_neg) {
        out[0] = left_mag > mag ? -1 : 1;
    } else {
        out[0] = left_mag < mag ? -1 : 1;
    }
    return KILN_DB_OK;
}

int kiln_db_u64_cmp_text(int64_t hi, int64_t lo, const char *text, int64_t *out, int n) {
    uint64_t value;
    int index = 0;
    int overflow = 0;
    uint64_t mag = 0;
    if (!out || n < 1) {
        return KILN_DB_CONFIG;
    }
    if (join_u64(hi, lo, &value) != 0) {
        return KILN_DB_ERR;
    }
    if (!text || !text[0]) {
        return KILN_DB_CONFIG;
    }
    if (text[0] == '-') {
        out[0] = 1;
        return KILN_DB_OK;
    }
    if (text[0] == '+') {
        return KILN_DB_CONFIG;
    }
    if (!scan_digits(text, &index, &overflow, &mag) || text[index] != 0) {
        return KILN_DB_CONFIG;
    }
    if (overflow) {
        out[0] = -1;
        return KILN_DB_OK;
    }
    if (value == mag) {
        out[0] = 0;
    } else if (value < mag) {
        out[0] = -1;
    } else {
        out[0] = 1;
    }
    return KILN_DB_OK;
}

const char *kiln_db_i64_text(int64_t hi, int64_t lo) {
    int64_t value;
    if (join_i64(hi, lo, &value) != 0) {
        num_text[0] = 0;
        return num_text;
    }
    snprintf(num_text, sizeof num_text, "%lld", (long long)value);
    return num_text;
}

const char *kiln_db_u64_text(int64_t hi, int64_t lo) {
    uint64_t value;
    if (join_u64(hi, lo, &value) != 0) {
        num_text[0] = 0;
        return num_text;
    }
    snprintf(num_text, sizeof num_text, "%llu", (unsigned long long)value);
    return num_text;
}
