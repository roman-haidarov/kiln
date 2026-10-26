#include <limits.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "../ext/kiln_cache.h"

__thread int sp_ffi_bin_len;

#define CF_KEYS    8
#define CF_ENTRIES 4
#define CF_BYTES   600
#define CF_VALUE   200

typedef struct {
    int present;
    size_t len;
    unsigned char bytes[256];
} cf_ref;

static long cf_small = -1;
static long cf_exact = -1;

int LLVMFuzzerInitialize(int *argc, char ***argv) {
    (void)argc;
    (void)argv;
    cf_small = kiln_cache_new(2, CF_ENTRIES, CF_BYTES, CF_VALUE);
    cf_exact = kiln_cache_new(1, CF_KEYS, 8192, CF_VALUE);
    return cf_small < 0 || cf_exact < 0;
}

static void cf_fill(unsigned char *out, size_t len, unsigned key, unsigned version) {
    for (size_t i = 0; i < len; i++) {
        out[i] = (unsigned char)((key * 31u) + (version * 7u) + (unsigned)i);
    }
}

static void cf_check_limits(long handle, long entries, long bytes) {
    int64_t stats[KILN_CACHE_STATS];
    if (kiln_cache_stats(handle, stats, KILN_CACHE_STATS) != KILN_CACHE_STATS ||
        stats[0] > entries || stats[1] > bytes || stats[0] < 0 || stats[1] < 0) {
        abort();
    }
}

static void cf_check(long handle, cf_ref *ref, unsigned key, int exact) {
    char name[2] = {(char)key, 0};
    long klen = key == 0 ? 0 : 2;
    const char *got =
        key & 1 ? kiln_cache_get_try(handle, name, klen) : kiln_cache_get(handle, name, klen);
    long found = kiln_cache_found();
    if (found == 1) {
        if (!ref[key].present || (size_t)sp_ffi_bin_len != ref[key].len ||
            (ref[key].len && memcmp(got, ref[key].bytes, ref[key].len) != 0)) {
            abort();
        }
    } else if (found != 0 || (exact && ref[key].present)) {
        abort();
    } else {
        ref[key].present = 0;
    }
}

static void cf_zero_sweep(long handle) {
    int64_t before[KILN_CACHE_STATS], after[KILN_CACHE_STATS];
    if (kiln_cache_stats(handle, before, KILN_CACHE_STATS) != KILN_CACHE_STATS ||
        kiln_cache_sweep(handle, 0) != 0 ||
        kiln_cache_stats(handle, after, KILN_CACHE_STATS) != KILN_CACHE_STATS ||
        memcmp(before, after, sizeof(before)) != 0) {
        abort();
    }
}

static long cf_reopen(long handle, int exact) {
    if (kiln_cache_free(handle) != 0) {
        abort();
    }
    long fresh = kiln_cache_new(
        exact ? 1 : 2, exact ? CF_KEYS : CF_ENTRIES, exact ? 8192 : CF_BYTES, CF_VALUE);
    int64_t stats[KILN_CACHE_STATS];
    if (fresh < 0 || fresh == handle || kiln_cache_open(handle) != 0 ||
        kiln_cache_set(handle, "x", 1, "y", 1, 0) != -1 ||
        kiln_cache_delete(handle, "x", 1) != -1 || kiln_cache_sweep(handle, 0) != -1 ||
        kiln_cache_clear(handle) != -1 || kiln_cache_free(handle) != -1 ||
        kiln_cache_stats(handle, stats, KILN_CACHE_STATS) != -1) {
        abort();
    }
    kiln_cache_get(handle, "x", 1);
    if (kiln_cache_found() != -1 || sp_ffi_bin_len != 0) {
        abort();
    }
    return fresh;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    cf_ref small[CF_KEYS] = {0}, exact[CF_KEYS] = {0};
    kiln_cache_clear(cf_small);
    kiln_cache_clear(cf_exact);
    unsigned version = 0;
    size_t pos = 0;
    while (pos + 2 < size) {
        unsigned op = data[pos] % 8u;
        unsigned key = data[pos + 1] % CF_KEYS;
        size_t vlen = data[pos + 2];
        pos += 3;
        char name[2] = {(char)key, 0};
        long klen = key == 0 ? 0 : 2;
        if (op < 3) {
            unsigned char value[256];
            cf_fill(value, vlen, key, ++version);
            long ttl = op == 2 ? LONG_MAX : 0;
            long stored =
                op == 1 ? kiln_cache_set_try(cf_small, name, klen, (const char *)value, (long)vlen, ttl)
                        : kiln_cache_set(cf_small, name, klen, (const char *)value, (long)vlen, ttl);
            long expected = vlen <= CF_VALUE;
            if (stored < 0 || kiln_cache_set(cf_exact, name, klen, (const char *)value, (long)vlen,
                                  ttl) != expected) {
                abort();
            }
            small[key].present = stored == 1;
            exact[key].present = (int)expected;
            small[key].len = exact[key].len = vlen;
            memcpy(small[key].bytes, value, vlen);
            memcpy(exact[key].bytes, value, vlen);
        } else if (op == 3) {
            cf_check(cf_small, small, key, 0);
        } else if (op == 4) {
            long gone = vlen & 1 ? kiln_cache_delete_try(cf_small, name, klen)
                                 : kiln_cache_delete(cf_small, name, klen);
            if (gone < 0 ||
                kiln_cache_delete(cf_exact, name, klen) != exact[key].present) {
                abort();
            }
            small[key].present = exact[key].present = 0;
        } else if (op == 5) {
            cf_zero_sweep(cf_small);
            cf_zero_sweep(cf_exact);
            if (kiln_cache_sweep(cf_small, (long)vlen) != 0 ||
                kiln_cache_sweep(cf_exact, (long)vlen) != 0) {
                abort();
            }
        } else if (op == 6) {
            kiln_cache_clear(cf_small);
            kiln_cache_clear(cf_exact);
            memset(small, 0, sizeof(small));
            memset(exact, 0, sizeof(exact));
        } else {
            cf_small = cf_reopen(cf_small, 0);
            cf_exact = cf_reopen(cf_exact, 1);
            memset(small, 0, sizeof(small));
            memset(exact, 0, sizeof(exact));
        }
        for (unsigned index = 0; index < CF_KEYS; index++) {
            cf_check(cf_exact, exact, index, 1);
        }
        cf_check_limits(cf_small, CF_ENTRIES, CF_BYTES);
        cf_check_limits(cf_exact, CF_KEYS, 8192);
    }
    return 0;
}
