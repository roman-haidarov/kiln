#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <limits.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "../ext/kiln_ascii.h"
#include "../ext/kiln_uv_parse.h"

__thread int sp_ffi_bin_len;

long kiln_scan_request_head(const char *buf, long len, int64_t *out, long cap);

static const long kiln_fuzz_bodies[] = {0, 1, 4, 1024, 1024L * 1024L, 999999999999999999L};

static int reference_token(const char *s, long len, const char *token) {
    long n = (long)strlen(token);
    long i = 0;
    while (i < len) {
        while (i < len && (s[i] == ' ' || s[i] == '\t' || s[i] == ','))
            i++;
        long start = i;
        while (i < len && s[i] != ',')
            i++;
        long end = i;
        while (end > start && (s[end - 1] == ' ' || s[end - 1] == '\t'))
            end--;
        if (end - start == n && kiln_ascii_case_equal(s + start, token, (size_t)n))
            return 1;
    }
    return 0;
}

static long reference_digits(const char *s, long len, long *value) {
    long v = 0;
    if (len <= 0 || len > 18)
        return -1;
    for (long i = 0; i < len; i++) {
        if (s[i] < '0' || s[i] > '9')
            return -1;
        v = v * 10 + (s[i] - '0');
    }
    *value = v;
    return 0;
}

static int reference_head(
    const char *start, size_t avail, kiln_uv_parse_result *out, long *head_len) {
    const char *end = memmem(start, avail, "\r\n\r\n", 4);
    if (!end) {
        if (avail > 16384) {
            out->error_status = 431;
            return KILN_UV_PARSE_ERROR;
        }
        return KILN_UV_PARSE_INCOMPLETE;
    }
    *head_len = (long)(end - start);
    if (*head_len > 16384) {
        out->error_status = 431;
        return KILN_UV_PARSE_ERROR;
    }
    return KILN_UV_PARSE_COMPLETE;
}

static int reference_coding(const char *s, long len) {
    long parts = 0;
    long start = 0;
    int last = 0;
    int seen = 0;
    for (long i = 0; i <= len; i++) {
        if (i < len && s[i] != ',')
            continue;
        long a = start;
        long b = i;
        while (a < b && (s[a] == ' ' || s[a] == '\t'))
            a++;
        while (b > a && (s[b - 1] == ' ' || s[b - 1] == '\t'))
            b--;
        if (a == b)
            return 400;
        last = b - a == 7 && kiln_ascii_case_equal(s + a, "chunked", 7);
        seen += last;
        parts++;
        start = i + 1;
    }
    if (!last || seen > 1)
        return 400;
    return parts > 1 ? 501 : 0;
}

static int reference_parse(
    const char *start, size_t avail, long max_body, int64_t *scan, kiln_uv_parse_result *out) {
    memset(out, 0, sizeof *out);
    long head_len = 0;
    int head = reference_head(start, avail, out, &head_len);
    if (head != KILN_UV_PARSE_COMPLETE)
        return head;
    long n = kiln_scan_request_head(start, head_len, scan, 5 + 5 * 100);
    if (n < 0) {
        out->error_status = 400;
        return KILN_UV_PARSE_ERROR;
    }
    long body = 0;
    int bad = 0;
    int minor = (int)(scan[4] & 1);
    int length = 0;
    int upgrade_token = 0;
    int upgrade = 0;
    const int64_t *coding = NULL;
    for (long i = 0; i < n; i++) {
        const int64_t *h = scan + 5 + 5 * i;
        if (h[4] == 23)
            coding = h;
        else if (h[4] == 6) {
            length = 1;
            if (reference_digits(start + h[2], (long)h[3], &body) < 0)
                bad = 400;
        } else if (h[4] == 5) {
            out->has_close |= reference_token(start + h[2], (long)h[3], "close");
            out->has_keep |= reference_token(start + h[2], (long)h[3], "keep-alive");
            upgrade_token |= reference_token(start + h[2], (long)h[3], "upgrade");
        } else if (h[4] == 24) {
            if (h[3] == 12 && kiln_ascii_case_equal(start + h[2], "100-continue", 12))
                out->expect_continue = minor == 1;
            else if (h[3] > 0)
                bad = 417;
        } else if (h[4] < 0 && h[1] == 7 && kiln_ascii_case_equal(start + h[0], "upgrade", 7) &&
                   h[3] > 0) {
            upgrade = 1;
        }
    }
    if (!bad && coding) {
        if (minor == 0 || length)
            bad = 400;
        else
            bad = reference_coding(start + coding[2], (long)coding[3]);
        out->chunked = !bad;
        body = 0;
    }
    if (bad) {
        out->error_status = bad;
        return KILN_UV_PARSE_ERROR;
    }
    out->streamed = out->chunked || body > max_body || body > LONG_MAX - head_len - 4;
    out->upgrade = upgrade && upgrade_token && minor == 1;
    out->head_len = (size_t)head_len;
    out->total_len = (size_t)head_len + 4 + (out->streamed ? 0 : (size_t)body);
    out->body_len = out->chunked ? -1 : body;
    out->nheaders = n;
    out->minor = minor;
    return avail < out->total_len ? KILN_UV_PARSE_INCOMPLETE : KILN_UV_PARSE_COMPLETE;
}

static int same_result(int state, const kiln_uv_parse_result *a, const kiln_uv_parse_result *b,
    const int64_t *left, const int64_t *right) {
    if (state == KILN_UV_PARSE_ERROR)
        return a->error_status == b->error_status;
    if (a->head_len != b->head_len || a->total_len != b->total_len || a->body_len != b->body_len ||
        a->nheaders != b->nheaders || a->minor != b->minor || a->has_close != b->has_close ||
        a->has_keep != b->has_keep || a->expect_continue != b->expect_continue ||
        a->streamed != b->streamed || a->chunked != b->chunked || a->upgrade != b->upgrade)
        return 0;
    if (a->nheaders == 0)
        return 1;
    return memcmp(left, right,
               sizeof(int64_t) * (size_t)(5 + KILN_HTTP_SCAN_STRIDE * a->nheaders)) == 0;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (!data || size == 0 || size > 32769)
        return 0;
    long max_body = kiln_fuzz_bodies[data[0] % 6];
    const char *text = (const char *)data + 1;
    size_t len = size - 1;
    int64_t left[KILN_UV_SCAN_CAP];
    int64_t right[KILN_UV_SCAN_CAP];
    kiln_uv_parse_result expected;
    kiln_uv_parse_result actual;
    int want = reference_parse(text, len, max_body, left, &expected);
    int got = kiln_uv_parse_request(text, len, max_body, right, KILN_UV_SCAN_CAP, &actual);
    if (want != got || !same_result(want, &expected, &actual, left, right))
        abort();
    return 0;
}
