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
#define KUV_CHUNK_LINE_MAX    4096
#define KUV_CHUNK_EXCESS      (16L * 1024)

long kiln_scan_request_head(const char *buf, long len, int64_t *out, long cap);
long kiln_chunk_size(const char *s, long len, long max);
long kiln_token(const char *s, long len);
long kiln_ctl(const char *s, long len);

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

static int kuv_transfer_coding(const char *s, long len) {
    long i = 0;
    long codings = 0;
    int last_chunked = 0;
    int chunked_seen = 0;
    while (i <= len) {
        long start = i;
        while (i < len && s[i] != ',') {
            i++;
        }
        long end = i;
        while (start < end && (s[start] == ' ' || s[start] == '\t')) {
            start++;
        }
        while (end > start && (s[end - 1] == ' ' || s[end - 1] == '\t')) {
            end--;
        }
        if (end == start) {
            return 400;
        }
        last_chunked = end - start == 7 && kiln_ascii_case_equal(s + start, "chunked", 7);
        chunked_seen += last_chunked;
        codings++;
        i++;
    }
    if (!last_chunked || chunked_seen > 1) {
        return 400;
    }
    return codings > 1 ? 501 : 0;
}

static int kuv_is_upgrade_name(const char *data, const int64_t *h) {
    return h[4] < 0 && h[1] == 7 && kiln_ascii_case_equal(data + h[0], "upgrade", 7);
}

typedef struct {
    long body;
    int bad;
    int minor;
    int has_length;
    int upgrade_token;
    int upgrade_field;
    const int64_t *coding;
} kuv_fields;

static void kuv_note_field(
    const char *data, const int64_t *h, kuv_fields *f, kiln_uv_parse_result *result) {
    if (h[4] == KUV_TRANSFER_ENCODING) {
        f->coding = h;
    } else if (h[4] == KUV_CONTENT_LENGTH) {
        f->has_length = 1;
        if (kuv_digits(data + h[2], (long)h[3], &f->body) < 0) {
            f->bad = 400;
        }
    } else if (h[4] == KUV_CONNECTION) {
        result->has_close |= kuv_has_token(data + h[2], (long)h[3], "close");
        result->has_keep |= kuv_has_token(data + h[2], (long)h[3], "keep-alive");
        f->upgrade_token |= kuv_has_token(data + h[2], (long)h[3], "upgrade");
    } else if (h[4] == KUV_EXPECT) {
        if (h[3] == 12 && kiln_ascii_case_equal(data + h[2], "100-continue", 12)) {
            result->expect_continue = f->minor == 1;
        } else if (h[3] > 0) {
            f->bad = 417;
        }
    } else if (kuv_is_upgrade_name(data, h) && h[3] > 0) {
        f->upgrade_field = 1;
    }
}

static void kuv_check_coding(const char *data, kuv_fields *f, kiln_uv_parse_result *result) {
    if (f->bad || !f->coding) {
        return;
    }
    if (f->minor == 0 || f->has_length) {
        f->bad = 400;
        return;
    }
    f->bad = kuv_transfer_coding(data + f->coding[2], (long)f->coding[3]);
    result->chunked = !f->bad;
    f->body = 0;
}

static int kuv_parse_headers(const char *data, size_t head_len, long max_body, int64_t *scan,
    long cap, kiln_uv_parse_result *result) {
    long count = kiln_scan_request_head(data, (long)head_len, scan, cap);
    if (count < 0) {
        result->error_status = 400;
        return KILN_UV_PARSE_ERROR;
    }
    kuv_fields f = {0, 0, (int)(scan[4] & 1), 0, 0, 0, NULL};
    for (long i = 0; i < count; i++) {
        kuv_note_field(data, scan + 5 + (KILN_UV_STRIDE * i), &f, result);
    }
    kuv_check_coding(data, &f, result);
    if (f.bad) {
        result->error_status = f.bad;
        return KILN_UV_PARSE_ERROR;
    }
    long body = f.body;
    int streamed = result->chunked || body > max_body || body > LONG_MAX - (long)head_len - 4;
    result->head_len = head_len;
    result->body_len = result->chunked ? -1 : body;
    result->nheaders = count;
    result->minor = f.minor;
    result->streamed = streamed;
    result->upgrade = f.upgrade_field && f.upgrade_token && f.minor == 1;
    result->total_len = head_len + 4 + (streamed ? 0 : (size_t)body);
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

void kiln_uv_chunk_init(kiln_uv_chunk_state *state) {
    state->phase = KILN_UV_CHUNK_SIZE;
    state->left = 0;
    state->excess = 0;
    state->trailer = 0;
}

static int kuv_chunk_line(const char *in, size_t in_len, size_t *line_len) {
    const char *end = memchr(in, '\n', in_len);
    if (!end) {
        return in_len > KUV_CHUNK_LINE_MAX ? KILN_UV_CHUNK_BAD : KILN_UV_CHUNK_MORE;
    }
    size_t len = (size_t)(end - in);
    if (len == 0 || in[len - 1] != '\r' || len > KUV_CHUNK_LINE_MAX + 1) {
        return KILN_UV_CHUNK_BAD;
    }
    *line_len = len - 1;
    return KILN_UV_CHUNK_END;
}

static int kuv_chunk_size_line(kiln_uv_chunk_state *state, const char *in, size_t line_len) {
    long size = kiln_chunk_size(in, (long)line_len, LONG_MAX / 4);
    if (size < 0) {
        return KILN_UV_CHUNK_BAD;
    }
    state->excess +=
        (long)line_len + 2 - 16 - (size > KUV_CHUNK_EXCESS ? KUV_CHUNK_EXCESS : size) * 2;
    if (state->excess < 0) {
        state->excess = 0;
    }
    if (state->excess > KUV_CHUNK_EXCESS) {
        return KILN_UV_CHUNK_BAD;
    }
    state->left = size;
    state->phase = size == 0 ? KILN_UV_CHUNK_TRAILER : KILN_UV_CHUNK_DATA;
    return KILN_UV_CHUNK_MORE;
}

static int kuv_forbidden_trailer(const char *name, size_t len) {
    static const char *const names[] = {"content-length", "transfer-encoding", "host", "connection",
        "trailer", "te", "upgrade", NULL};
    for (int i = 0; names[i]; i++) {
        if (strlen(names[i]) == len && kiln_ascii_case_equal(name, names[i], len)) {
            return 1;
        }
    }
    return 0;
}

static int kuv_chunk_trailer_line(kiln_uv_chunk_state *state, const char *in, size_t line_len) {
    if (line_len == 0) {
        state->phase = KILN_UV_CHUNK_DONE;
        return KILN_UV_CHUNK_END;
    }
    state->trailer += (long)line_len + 2;
    if (state->trailer > KILN_UV_HEAD_MAX) {
        return KILN_UV_CHUNK_TOO_BIG;
    }
    const char *colon = memchr(in, ':', line_len);
    if (!colon || colon == in || !kiln_token(in, (long)(colon - in)) ||
        kuv_forbidden_trailer(in, (size_t)(colon - in))) {
        return KILN_UV_CHUNK_BAD;
    }
    size_t value = (size_t)(colon - in) + 1;
    return kiln_ctl(in + value, (long)(line_len - value)) ? KILN_UV_CHUNK_BAD : KILN_UV_CHUNK_MORE;
}

int kiln_uv_chunk_decode(kiln_uv_chunk_state *state, const char *in, size_t in_len, char *out,
    size_t out_cap, size_t *consumed, size_t *produced) {
    size_t pos = 0;
    size_t made = 0;
    int status = KILN_UV_CHUNK_MORE;
    while (status == KILN_UV_CHUNK_MORE && state->phase != KILN_UV_CHUNK_DONE) {
        if (state->phase == KILN_UV_CHUNK_DATA) {
            size_t take = in_len - pos;
            if ((size_t)state->left < take) {
                take = (size_t)state->left;
            }
            if (out_cap - made < take) {
                take = out_cap - made;
            }
            if (take == 0) {
                break;
            }
            memcpy(out + made, in + pos, take);
            made += take;
            pos += take;
            state->left -= (long)take;
            if (state->left == 0) {
                state->phase = KILN_UV_CHUNK_DATA_END;
            }
            continue;
        }
        if (state->phase == KILN_UV_CHUNK_DATA_END) {
            if (in_len - pos < 2) {
                break;
            }
            if (in[pos] != '\r' || in[pos + 1] != '\n') {
                status = KILN_UV_CHUNK_BAD;
                break;
            }
            pos += 2;
            state->phase = KILN_UV_CHUNK_SIZE;
            continue;
        }
        size_t line_len = 0;
        int line = kuv_chunk_line(in + pos, in_len - pos, &line_len);
        if (line != KILN_UV_CHUNK_END) {
            status = line;
            break;
        }
        status = state->phase == KILN_UV_CHUNK_SIZE
                     ? kuv_chunk_size_line(state, in + pos, line_len)
                     : kuv_chunk_trailer_line(state, in + pos, line_len);
        if (status >= KILN_UV_CHUNK_MORE) {
            pos += line_len + 2;
        }
    }
    *consumed = pos;
    *produced = made;
    return status;
}
