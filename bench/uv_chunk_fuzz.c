#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "../ext/kiln_uv_parse.h"

__thread int sp_ffi_bin_len;

static int kiln_fuzz_incremental(
    const char *in, size_t len, size_t step, size_t cap, char *out, size_t *made, size_t *used) {
    kiln_uv_chunk_state state;
    char piece[16];
    size_t fed = step < len ? step : len;
    size_t off = 0;
    int rc = KILN_UV_CHUNK_MORE;
    kiln_uv_chunk_init(&state);
    *made = 0;
    for (;;) {
        size_t consumed = 0;
        size_t produced = 0;
        rc = kiln_uv_chunk_decode(&state, in + off, fed - off, piece, cap, &consumed, &produced);
        memcpy(out + *made, piece, produced);
        *made += produced;
        off += consumed;
        if (rc != KILN_UV_CHUNK_MORE)
            break;
        if (consumed == 0 && produced == 0) {
            if (fed == len)
                break;
            fed = fed + step < len ? fed + step : len;
        }
    }
    *used = off;
    return rc;
}

static int kiln_fuzz_step(
    const char *in, size_t len, size_t step, size_t cap, char *out, size_t *made, size_t *used) {
    int64_t state[6] = {KILN_UV_CHUNK_SIZE, 0, 0, 0, 0, 0};
    size_t fed = step < len ? step : len;
    size_t off = 0;
    *made = 0;
    for (;;) {
        const char *piece = kiln_chunk_step(in, (long)fed, (long)off, (long)cap, state);
        size_t produced = (size_t)sp_ffi_bin_len;
        memcpy(out + *made, piece, produced);
        *made += produced;
        off += (size_t)state[4];
        *used = off;
        if (state[5] != KILN_UV_CHUNK_MORE)
            return (int)state[5];
        if (state[4] == 0 && produced == 0) {
            if (fed == len)
                return (int)state[5];
            fed = fed + step < len ? fed + step : len;
        }
    }
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (!data || size < 2 || size > 65536)
        return 0;
    size_t step = (size_t)(data[0] % 17) + 1;
    size_t cap = (size_t)(data[1] % 13) + 1;
    const char *in = (const char *)data + 2;
    size_t len = size - 2;
    char *whole = malloc(len + 1);
    char *split = malloc(len + 1);
    if (!whole || !split)
        abort();
    kiln_uv_chunk_state state;
    kiln_uv_chunk_init(&state);
    size_t consumed = 0;
    size_t produced = 0;
    int rc = kiln_uv_chunk_decode(&state, in, len, whole, len + 1, &consumed, &produced);
    size_t made = 0;
    size_t used = 0;
    int got = kiln_fuzz_incremental(in, len, step, cap, split, &made, &used);
    if (consumed > len || produced > len || made > len || used > len)
        abort();
    if (rc != got || produced != made || memcmp(whole, split, produced) != 0)
        abort();
    size_t stepped = 0;
    size_t step_used = 0;
    int via_step = kiln_fuzz_step(in, len, step, cap, split, &stepped, &step_used);
    if (via_step != rc || stepped != produced || memcmp(whole, split, produced) != 0)
        abort();
    if (rc == KILN_UV_CHUNK_END && step_used != consumed)
        abort();
    if (rc == KILN_UV_CHUNK_END && (consumed != used || state.phase != KILN_UV_CHUNK_DONE))
        abort();
    free(whole);
    free(split);
    return 0;
}
