#include "kiln_db.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#ifdef SP_THREADS
__thread int sp_ffi_bin_len;
#else
int sp_ffi_bin_len;
#endif

static int fail(const char *label) {
    printf("asan-fail %s\n", label);
    return 1;
}

static int check_number(void) {
    int64_t words[4];
    int64_t out[4];
    int64_t cmp = 99;
    if (kiln_db_i64_parse("-9223372036854775808", words, 2) != KILN_DB_OK) {
        return fail("i64-min");
    }
    if (words[0] != (int64_t)(-2147483647 - 1) || words[1] != 0) {
        return fail("i64-words");
    }
    if (kiln_db_i64_apply(KILN_DB_NUM_DIV, -1, 4294967291LL, 0, 2, out, 4) != KILN_DB_OK) {
        return fail("div");
    }
    if (out[0] != -1 || out[1] != 4294967294LL || out[2] != -1 || out[3] != 4294967295LL) {
        return fail("div-words");
    }
    if (kiln_db_i64_apply(KILN_DB_NUM_DIV, words[0], words[1], -1, 4294967295LL, out, 4) !=
        KILN_DB_ERR) {
        return fail("div-min");
    }
    if (kiln_db_u64_parse("9223372036854775808", words, 2) != KILN_DB_OK) {
        return fail("u64");
    }
    if (words[0] != 2147483648LL || words[1] != 0) {
        return fail("u64-words");
    }
    if (kiln_db_u64_cmp_text(words[0], words[1], "9223372036854775808", &cmp, 1) != KILN_DB_OK ||
        cmp != 0) {
        return fail("u64-cmp");
    }
    printf("asan-number\n");
    return 0;
}

static int check_resolve(void) {
    int64_t values[8] = {65536, 1024, 4096, 67108864, 8, 64, 16, 5000};
    int wait_fd = -1;
    int done = 0;
    char addr[64];
    int rc;
    if (kiln_db_configure_values(values, 8) != KILN_DB_OK) {
        return fail("configure");
    }
    rc = kiln_db_resolver_submit("127.0.0.1", 9, &wait_fd, addr, sizeof addr, &done);
    if (rc != 0 || done != 1 || strcmp(addr, "127.0.0.1") != 0) {
        return fail("resolve");
    }
    printf("asan-resolve\n");
    return 0;
}

static int check_stale(void) {
    int64_t err = 0;
    int64_t out[8];
    uint64_t handle = kiln_db_conn_create(KILN_DB_KIND_PG, 1, 1, &err);
    int rc;
    if (!handle || err != KILN_DB_OK) {
        return fail("create");
    }
    rc = kiln_db_step(handle, 1, 1, KILN_DB_OP_CLOSE, 0, 0, out, 8);
    if (rc != KILN_DB_OK || out[0] != KILN_DB_STEP_DONE) {
        return fail("close");
    }
    kiln_db_step(handle, 1, 1, KILN_DB_OP_EXEC, 0, 0, out, 8);
    if (out[0] != KILN_DB_STEP_ERR || out[4] != KILN_DB_STALE) {
        return fail("stale");
    }
    printf("asan-stale\n");
    return 0;
}

static int check_null_result_rows(void) {
    int64_t lens[1];
    int64_t nums[1];
    int64_t meta[3];
    double floats[1];
    const char *out;
    out = kiln_db_my_result_rows(NULL, 0, 1, 1, lens, 1, meta);
    if (!out || out[0] || sp_ffi_bin_len || meta[0] != -2 || meta[1] || meta[2]) {
        return fail("my-null-rows");
    }
    out = kiln_db_my_result_rows_typed(NULL, 0, 1, 1, lens, 1, nums, floats, meta);
    if (!out || out[0] || sp_ffi_bin_len || meta[0] != -2 || meta[1] || meta[2]) {
        return fail("my-null-typed-rows");
    }
    out = kiln_db_pg_result_rows(NULL, 0, 1, 1, lens, 1, meta);
    if (!out || out[0] || sp_ffi_bin_len || meta[0] != -2 || meta[1] || meta[2]) {
        return fail("pg-null-rows");
    }
    out = kiln_db_pg_result_rows_typed(NULL, 0, 1, 1, lens, 1, nums, floats, meta);
    if (!out || out[0] || sp_ffi_bin_len || meta[0] != -2 || meta[1] || meta[2]) {
        return fail("pg-null-typed-rows");
    }
    printf("asan-null-result-rows\n");
    return 0;
}

int main(void) {
    if (check_number() || check_resolve() || check_stale() || check_null_result_rows()) {
        return 1;
    }
    printf("asan-no-session\n");
    return 0;
}
