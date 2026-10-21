#include "kiln_db.h"

#include <stdint.h>
#include <string.h>

int kiln_db_bitset_and(uint64_t *dst, const uint64_t *a, const uint64_t *b, uint32_t words) {
    uint32_t i;
    if (!dst || !a || !b) {
        return KILN_DB_ERR;
    }
    for (i = 0; i < words; i++) {
        dst[i] = a[i] & b[i];
    }
    return KILN_DB_OK;
}

int kiln_db_bitset_or(uint64_t *dst, const uint64_t *a, const uint64_t *b, uint32_t words) {
    uint32_t i;
    if (!dst || !a || !b) {
        return KILN_DB_ERR;
    }
    for (i = 0; i < words; i++) {
        dst[i] = a[i] | b[i];
    }
    return KILN_DB_OK;
}

int kiln_db_bitset_not(uint64_t *dst, const uint64_t *a, uint32_t bits, uint32_t words) {
    uint32_t i;
    uint32_t whole;
    uint32_t rem;
    if (!dst || !a) {
        return KILN_DB_ERR;
    }
    if (bits > words * 64u) {
        return KILN_DB_ERR;
    }
    whole = bits / 64u;
    rem = bits % 64u;
    for (i = 0; i < whole; i++) {
        dst[i] = ~a[i];
    }
    if (rem) {
        uint64_t mask = (1ull << rem) - 1ull;
        dst[whole] = (~a[whole]) & mask;
        i = whole + 1;
    }
    for (; i < words; i++) {
        dst[i] = 0;
    }
    return KILN_DB_OK;
}
