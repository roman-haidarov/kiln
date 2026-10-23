#include <stdint.h>
#include <stdlib.h>
#include "../ext/kiln_uv_parse.h"

__thread int sp_ffi_bin_len;

static const long kiln_fuzz_bodies[] = {0, 1, 4, 1024, 1024L * 1024L, 999999999999999999L};

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (!data || size == 0 || size > 32769)
        return 0;
    long max_body = kiln_fuzz_bodies[data[0] % 6];
    const char *text = (const char *)data + 1;
    size_t len = size - 1;
    int64_t scan[KILN_UV_SCAN_CAP];
    kiln_uv_parse_result result;
    int state = kiln_uv_parse_request(text, len, max_body, scan, KILN_UV_SCAN_CAP, &result);
    if (state < 0)
        abort();
    if (state == KILN_UV_PARSE_ERROR) {
        if (result.error_status != 400 && result.error_status != 413 &&
            result.error_status != 417 && result.error_status != 431 && result.error_status != 501)
            abort();
        return 0;
    }
    if (state == KILN_UV_PARSE_INCOMPLETE) {
        if (result.total_len && result.total_len <= len)
            abort();
        return 0;
    }
    if (result.streamed && result.total_len != result.head_len + 4)
        abort();
    if (result.chunked && (!result.streamed || result.body_len != -1))
        abort();
    if (!result.streamed && result.body_len > max_body)
        abort();
    if (state != KILN_UV_PARSE_COMPLETE || result.total_len > len ||
        result.head_len + 4 > result.total_len || (!result.chunked && result.body_len < 0) ||
        result.nheaders < 0 || result.nheaders > KILN_UV_MAX_HEADERS || result.minor < 0 ||
        result.minor > 1)
        abort();
    if (scan[4] < 0 || scan[4] > 3)
        abort();
    for (long i = 0; i < result.nheaders; i++) {
        long at = 5 + KILN_UV_STRIDE * i;
        if (scan[at] < 0 || scan[at + 1] < 0 ||
            scan[at] + scan[at + 1] > (int64_t)result.head_len || scan[at + 2] < 0 ||
            scan[at + 3] < 0 || scan[at + 2] + scan[at + 3] > (int64_t)result.head_len ||
            scan[at + 4] < -1 || scan[at + 4] > 31)
            abort();
    }
    return 0;
}
