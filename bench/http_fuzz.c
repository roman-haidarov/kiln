#include <limits.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

__thread int sp_ffi_bin_len;

long kiln_chunk_size(const char *text, long len, long max);
long kiln_token(const char *text, long len);
long kiln_ctl(const char *text, long len);
long kiln_digits(const char *text, long len);
long kiln_host(const char *text, long len);
long kiln_http_accepts_gzip(const char *text, long len);

#if KILN_FUZZ_KIND == 0
long kiln_http_scan(const char *head, long len, int64_t *out, long cap);
long kiln_http_scan_at(const char *data, long total, long start, long len, int64_t *out, long cap);

static int kiln_fuzz_span(int64_t start, int64_t len, int64_t lower, int64_t upper) {
    if (start < lower || len < 0 || start > upper)
        return 0;
    return len <= upper - start;
}

static void kiln_fuzz_result(const int64_t *out, long count, long base, long len) {
    if (count < 0)
        return;
    if (count > 100 || out[4] < 0 || out[4] > 3)
        abort();
    int64_t lower = base;
    int64_t upper = base + len;
    if (!kiln_fuzz_span(out[0], out[1], lower, upper) ||
        !kiln_fuzz_span(out[2], out[3], lower, upper))
        abort();
    for (long i = 0; i < count; i++) {
        long at = 5 + 5 * i;
        if (!kiln_fuzz_span(out[at], out[at + 1], lower, upper) ||
            !kiln_fuzz_span(out[at + 2], out[at + 3], lower, upper) || out[at + 4] < -1 ||
            out[at + 4] > 31)
            abort();
    }
}
#endif

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (!data || size > 16384)
        return 0;
    const char *text = (const char *)data;
    long len = (long)size;
#if KILN_FUZZ_KIND == 0
    enum { OUT_CAP = 513, REQUIRED_CAP = 505 };
    int64_t out[OUT_CAP];
    long count = kiln_http_scan(text, len, out, OUT_CAP);
    kiln_fuzz_result(out, count, 0, len);
    char padded[16384 + 12];
    size_t prefix = size ? (size_t)(data[0] & 7U) : 0;
    if (size)
        memcpy(padded + prefix, data, size);
    memcpy(padded + prefix + size, "\r\n\r\n", 4);
    long total = (long)(prefix + size + 4);
    long cap = REQUIRED_CAP + (size ? data[0] & 7U : 0);
    count = kiln_http_scan_at(padded, total, (long)prefix, len, out, cap);
    kiln_fuzz_result(out, count, (long)prefix, len);
    if (count >= 0 &&
        kiln_http_scan_at(padded, total, (long)prefix, len, out, REQUIRED_CAP - 1) != -1)
        abort();
    kiln_http_scan_at(padded, total, -1, len, out, OUT_CAP);
#elif KILN_FUZZ_KIND == 1
    kiln_chunk_size(text, len, 1024 * 1024);
    kiln_chunk_size(text, len, LONG_MAX);
    kiln_chunk_size(text, len, 0);
#elif KILN_FUZZ_KIND == 2
    kiln_http_accepts_gzip(text, len);
#elif KILN_FUZZ_KIND == 3
    kiln_token(text, len);
#elif KILN_FUZZ_KIND == 4
    kiln_ctl(text, len);
#elif KILN_FUZZ_KIND == 5
    kiln_digits(text, len);
#elif KILN_FUZZ_KIND == 6
    kiln_host(text, len);
#else
#error Unsupported KILN_FUZZ_KIND
#endif
    return 0;
}
