#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <limits.h>
#include <stdint.h>
#include <string.h>
#include "kiln_ascii.h"
#include "kiln_uv_parse.h"

#define KUV_CONTENT_LENGTH    6
#define KUV_TRANSFER_ENCODING 23
#define KUV_CONNECTION        5
#define KUV_EXPECT            24

long kiln_scan_request_head(const char *buf, long len, int64_t *out, long cap);

static int kuv_has_token(const char *s, long len, const char *token) {
    long n = (long)strlen(token);
    long i = 0;
    while (i < len) {
        while (i < len && (s[i] == ' ' || s[i] == '\t' || s[i] == ',')) {
            i++;
        }
        long start = i;
        while (i < len && s[i] != ',') {
            i++;
        }
        long end = i;
        while (end > start && (s[end - 1] == ' ' || s[end - 1] == '\t')) {
            end--;
        }
        if (end - start == n && kiln_ascii_case_equal(s + start, token, (size_t)n)) {
            return 1;
        }
    }
    return 0;
}

static int kuv_digits(const char *s, long len, long *value) {
    long v = 0;
    if (len <= 0 || len > 18) {
        return -1;
    }
    for (long i = 0; i < len; i++) {
        int digit = s[i] - '0';
        if (digit < 0 || digit > 9 || v > (LONG_MAX - digit) / 10) {
            return -1;
        }
        v = (v * 10) + digit;
    }
    *value = v;
    return 0;
}

static int kuv_head_length(const char *data, size_t len, size_t *head_len, int *error_status) {
    const char *end = memmem(data, len, "\r\n\r\n", 4);
    if (!end) {
        if (len > KILN_UV_HEAD_MAX) {
            *error_status = 431;
            return KILN_UV_PARSE_ERROR;
        }
        return KILN_UV_PARSE_INCOMPLETE;
    }
    *head_len = (size_t)(end - data);
    if (*head_len > KILN_UV_HEAD_MAX) {
        *error_status = 431;
        return KILN_UV_PARSE_ERROR;
    }
    return KILN_UV_PARSE_COMPLETE;
}

static int kuv_parse_headers(const char *data, size_t head_len, long max_body, int64_t *scan,
    long cap, kiln_uv_parse_result *result) {
    long count = kiln_scan_request_head(data, (long)head_len, scan, cap);
    if (count < 0) {
        result->error_status = 400;
        return KILN_UV_PARSE_ERROR;
    }
    long body = 0;
    int bad = 0;
    int minor = (int)(scan[4] & 1);
    int has_close = 0;
    int has_keep = 0;
    int expect_continue = 0;
    for (long i = 0; i < count; i++) {
        const int64_t *h = scan + 5 + (KILN_UV_STRIDE * i);
        if (h[4] == KUV_TRANSFER_ENCODING) {
            bad = 501;
        } else if (h[4] == KUV_CONTENT_LENGTH) {
            if (kuv_digits(data + h[2], (long)h[3], &body) < 0) {
                bad = 400;
            }
        } else if (h[4] == KUV_CONNECTION) {
            has_close |= kuv_has_token(data + h[2], (long)h[3], "close");
            has_keep |= kuv_has_token(data + h[2], (long)h[3], "keep-alive");
        } else if (h[4] == KUV_EXPECT) {
            if (h[3] == 12 && kiln_ascii_case_equal(data + h[2], "100-continue", 12)) {
                expect_continue = minor == 1;
            } else if (h[3] > 0) {
                bad = 417;
            }
        }
    }
    if (!bad && (body > max_body || body > LONG_MAX - (long)head_len - 4)) {
        bad = 413;
    }
    if (bad) {
        result->error_status = bad;
        return KILN_UV_PARSE_ERROR;
    }
    result->head_len = head_len;
    result->body_len = body;
    result->nheaders = count;
    result->minor = minor;
    result->has_close = has_close;
    result->has_keep = has_keep;
    result->expect_continue = expect_continue;
    result->total_len = head_len + 4 + (size_t)body;
    return KILN_UV_PARSE_COMPLETE;
}

int kiln_uv_parse_request(const char *data, size_t len, long max_body, int64_t *scan, long cap,
    kiln_uv_parse_result *result) {
    if (!data || !scan || !result || len > LONG_MAX || max_body < 0 || cap < KILN_UV_SCAN_CAP) {
        return -1;
    }
    memset(result, 0, sizeof(*result));
    size_t head_len = 0;
    int head_state = kuv_head_length(data, len, &head_len, &result->error_status);
    if (head_state != KILN_UV_PARSE_COMPLETE) {
        return head_state;
    }
    int header_state = kuv_parse_headers(data, head_len, max_body, scan, cap, result);
    if (header_state != KILN_UV_PARSE_COMPLETE) {
        return header_state;
    }
    if (len < result->total_len) {
        return KILN_UV_PARSE_INCOMPLETE;
    }
    return KILN_UV_PARSE_COMPLETE;
}
