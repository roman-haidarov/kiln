#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <stdint.h>
#include <string.h>
#include <strings.h>
#include <errno.h>
#include <poll.h>
#include <sys/types.h>
#include <sys/socket.h>
#include "picohttpparser/picohttpparser.h"

#define KILN_MAX_HEAD    16384
#define KILN_MAX_HEADERS 100
#define KILN_STRIDE      5
#define KILN_RECV_MAX    16384

#ifdef SP_THREADS
extern __thread int sp_ffi_bin_len;
static __thread char kiln_rbuf[KILN_RECV_MAX];
static __thread long kiln_rstatus;
#else
extern int sp_ffi_bin_len;
static char kiln_rbuf[KILN_RECV_MAX];
static long kiln_rstatus;
#endif

static const char *const kiln_common[] = {
    "host", "user-agent", "accept", "accept-encoding", "accept-language", "connection",
    "content-length", "content-type", "cookie", "referer", "cache-control", "upgrade-insecure-requests",
    "sec-fetch-site", "sec-fetch-mode", "sec-fetch-user", "sec-fetch-dest", "sec-ch-ua",
    "sec-ch-ua-mobile", "sec-ch-ua-platform", "origin", "authorization", "if-none-match",
    "if-modified-since", "transfer-encoding", "expect", "x-forwarded-for", "x-request-id",
    "pragma", "priority", "te", "range", "dnt"
};

static long kiln_common_index(const char *name, size_t len) {
    for (size_t i = 0; i < sizeof(kiln_common) / sizeof(kiln_common[0]); i++) {
        const char *c = kiln_common[i];
        if (strlen(c) == len && strncasecmp(c, name, len) == 0)
            return (long)i;
    }
    return -1;
}

static int kiln_clean_value(const char *value, size_t len) {
    return len == 0 || memchr(value, '\t', len) == NULL;
}

static int kiln_ascii(const char *s, long len) {
    unsigned char acc = 0;
    for (long i = 0; i < len; i++)
        acc |= (unsigned char)s[i];
    return acc < 0x80;
}

static int kiln_crlf_only(const char *head, long len) {
    const char *end = head + len;
    for (const char *p = head; (p = memchr(p, '\n', (size_t)(end - p))) != NULL; p++) {
        if (p == head || p[-1] != '\r')
            return 0;
    }
    return 1;
}

static long kiln_scan_terminated(const char *buf, long len, int64_t *out, long cap, long base) {
    struct phr_header headers[KILN_MAX_HEADERS];
    const char *method;
    const char *path;
    size_t method_len;
    size_t path_len;
    size_t num = KILN_MAX_HEADERS;
    int minor = -1;

    if (len <= 0 || len > KILN_MAX_HEAD || cap < 5 + KILN_STRIDE * KILN_MAX_HEADERS)
        return -1;
    if (buf[0] == '\r' || buf[0] == '\n' || !kiln_crlf_only(buf, len))
        return -1;
    int used = phr_parse_request(buf, (size_t)len + 4, &method, &method_len, &path, &path_len,
                                 &minor, headers, &num, 0);
    if (used != len + 4)
        return -1;
    if (method != buf || path != buf + method_len + 1)
        return -1;
    size_t after = (size_t)(path - buf) + path_len;
    if (buf[after] != ' ' || buf[after + 1] != 'H')
        return -1;
    if (minor != 0 && minor != 1)
        return -1;
    out[0] = base;
    out[1] = (int64_t)method_len;
    out[2] = base + (int64_t)(path - buf);
    out[3] = (int64_t)path_len;
    out[4] = minor | (kiln_ascii(buf, len) << 1);
    long o = 5;
    int seen_host = 0;
    int seen_length = 0;
    int seen_encoding = 0;
    for (size_t i = 0; i < num; i++) {
        if (headers[i].name == NULL || !kiln_clean_value(headers[i].value, headers[i].value_len))
            return -1;
        out[o] = base + (int64_t)(headers[i].name - buf);
        out[o + 1] = (int64_t)headers[i].name_len;
        out[o + 2] = base + (int64_t)(headers[i].value - buf);
        out[o + 3] = (int64_t)headers[i].value_len;
        long known = kiln_common_index(headers[i].name, headers[i].name_len);
        if ((known == 0 && seen_host++) || (known == 6 && seen_length++) ||
            (known == 23 && seen_encoding++))
            return -1;
        out[o + 4] = known;
        o += KILN_STRIDE;
    }
    return (long)num;
}

long kiln_http_scan(const char *head, long len, int64_t *out, long cap) {
    char buf[KILN_MAX_HEAD + 4];
    if (len <= 0 || len > KILN_MAX_HEAD)
        return -1;
    memcpy(buf, head, (size_t)len);
    memcpy(buf + len, "\r\n\r\n", 4);
    return kiln_scan_terminated(buf, len, out, cap, 0);
}

long kiln_http_scan_at(const char *data, long total, long start, long len, int64_t *out, long cap) {
    if (total < 0 || start < 0 || len <= 0 || len > KILN_MAX_HEAD || start > total - len - 4)
        return -1;
    const char *buf = data + start;
    if (memcmp(buf + len, "\r\n\r\n", 4) != 0)
        return -1;
    return kiln_scan_terminated(buf, len, out, cap, start);
}

static int kiln_tchar(unsigned char c) {
    if ((c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'))
        return 1;
    switch (c) {
    case '!': case '#': case '$': case '%': case '&': case '\'': case '*': case '+':
    case '-': case '.': case '^': case '_': case '`': case '|': case '~':
        return 1;
    default:
        return 0;
    }
}

static int kiln_hex(unsigned char c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

static int kiln_alnum(unsigned char c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

static int kiln_subdelim(unsigned char c) {
    return c == '!' || c == '$' || c == '&' || c == '\'' || c == '(' || c == ')' || c == '*' ||
           c == '+' || c == ',' || c == ';' || c == '=';
}

long kiln_token(const char *s, long len) {
    if (len <= 0)
        return 0;
    for (long i = 0; i < len; i++)
        if (!kiln_tchar((unsigned char)s[i]))
            return 0;
    return 1;
}

long kiln_ctl(const char *s, long len) {
    for (long i = 0; i < len; i++) {
        unsigned char c = (unsigned char)s[i];
        if (c < 0x20 || c == 0x7f)
            return 1;
    }
    return 0;
}

long kiln_digits(const char *s, long len) {
    if (len <= 0)
        return 0;
    if (s[0] == '0')
        return len == 1;
    for (long i = 0; i < len; i++)
        if (s[i] < '0' || s[i] > '9')
            return 0;
    return 1;
}

static long kiln_ows(const char *s, long len, long i) {
    while (i < len && (s[i] == ' ' || s[i] == '\t'))
        i++;
    return i;
}

long kiln_chunk_size(const char *s, long len, long max) {
    long i = 0;
    long size = 0;
    int excess = 0;
    while (i < len && kiln_hex((unsigned char)s[i])) {
        unsigned char c = (unsigned char)s[i++];
        long digit = c <= '9' ? c - '0' : (c | 32) - 'a' + 10;
        if (!excess) {
            if (digit > max || size > (max - digit) / 16)
                excess = 1;
            else
                size = size * 16 + digit;
        }
    }
    if (i == 0)
        return -1;
    while (i < len) {
        i = kiln_ows(s, len, i);
        if (i >= len || s[i++] != ';')
            return -1;
        i = kiln_ows(s, len, i);
        long begin = i;
        while (i < len && kiln_tchar((unsigned char)s[i]))
            i++;
        if (i == begin)
            return -1;
        long after_name = i;
        i = kiln_ows(s, len, i);
        if (i == len)
            return i == after_name ? (excess ? -2 : size) : -1;
        if (s[i] != '=')
            continue;
        i = kiln_ows(s, len, i + 1);
        if (i == len)
            return -1;
        if (s[i] == '"') {
            i++;
            int closed = 0;
            while (i < len) {
                unsigned char c = (unsigned char)s[i++];
                if (c == '"') {
                    closed = 1;
                    break;
                }
                if (c == '\\') {
                    if (i == len)
                        return -1;
                    c = (unsigned char)s[i++];
                }
                if ((c < 32 && c != '\t') || c == 127)
                    return -1;
            }
            if (!closed)
                return -1;
        } else {
            begin = i;
            while (i < len && kiln_tchar((unsigned char)s[i]))
                i++;
            if (i == begin)
                return -1;
        }
    }
    return excess ? -2 : size;
}

long kiln_host(const char *s, long len) {
    long i = 0;
    if (len <= 0)
        return 0;
    if (s[0] == '[') {
        long close = -1;
        for (long j = 1; j < len; j++)
            if (s[j] == ']') {
                close = j;
                break;
            }
        if (close < 2)
            return 0;
        int plain = 1;
        for (long j = 1; j < close; j++) {
            unsigned char c = (unsigned char)s[j];
            if (!(kiln_hex(c) || c == ':' || c == '.' || c == '%')) {
                plain = 0;
                break;
            }
        }
        if (!plain) {
            long j = 1;
            if (s[j] != 'v' && s[j] != 'V')
                return 0;
            j++;
            long hex_start = j;
            while (j < close && kiln_hex((unsigned char)s[j]))
                j++;
            if (j == hex_start || j >= close || s[j] != '.')
                return 0;
            j++;
            if (j >= close)
                return 0;
            for (; j < close; j++) {
                unsigned char c = (unsigned char)s[j];
                if (!(kiln_alnum(c) || c == '.' || c == '_' || c == '~' || c == '-' || c == ':' ||
                      kiln_subdelim(c)))
                    return 0;
            }
        }
        i = close + 1;
    } else {
        while (i < len) {
            unsigned char c = (unsigned char)s[i];
            if (!(kiln_alnum(c) || c == '.' || c == '_' || c == '~' || c == '-' || c == '%' ||
                  kiln_subdelim(c)))
                break;
            i++;
        }
        if (i == 0)
            return 0;
    }
    if (i < len) {
        if (s[i] != ':' || i + 1 >= len)
            return 0;
        for (long j = i + 1; j < len; j++)
            if (s[j] < '0' || s[j] > '9')
                return 0;
    }
    for (long j = 0; j < len; j++)
        if (s[j] == '%' && (j + 2 >= len || !kiln_hex((unsigned char)s[j + 1]) ||
                            !kiln_hex((unsigned char)s[j + 2])))
            return 0;
    return 1;
}

const char *kiln_recv(long fd, long max) {
    ssize_t n;
    if (max <= 0 || max > KILN_RECV_MAX)
        max = KILN_RECV_MAX;
    do {
        n = recv((int)fd, kiln_rbuf, (size_t)max, MSG_DONTWAIT);
    } while (n < 0 && errno == EINTR);
    if (n > 0) {
        kiln_rstatus = (long)n;
        sp_ffi_bin_len = (int)n;
        return kiln_rbuf;
    }
    kiln_rstatus = n == 0 ? 0 : ((errno == EAGAIN || errno == EWOULDBLOCK) ? -1 : -2);
    sp_ffi_bin_len = 0;
    return kiln_rbuf;
}

long kiln_recv_status(void) {
    return kiln_rstatus;
}

long kiln_send(long fd, const char *data, long total, long off, long len) {
    ssize_t n;
    if (off < 0 || len < 0 || off > total || len > total - off)
        return -2;
    do {
        n = send((int)fd, data + off, (size_t)len, MSG_DONTWAIT | MSG_NOSIGNAL);
    } while (n < 0 && errno == EINTR);
    if (n >= 0)
        return (long)n;
    return (errno == EAGAIN || errno == EWOULDBLOCK) ? -1 : -2;
}

long kiln_peer_closed(long fd) {
#ifdef POLLRDHUP
    struct pollfd p;
    p.fd = (int)fd;
    p.events = POLLRDHUP;
    p.revents = 0;
    int r;
    do {
        r = poll(&p, 1, 0);
    } while (r < 0 && errno == EINTR);
    if (r < 0)
        return 1;
    return (p.revents & (POLLRDHUP | POLLHUP | POLLERR | POLLNVAL)) ? 1 : 0;
#else
    char byte;
    ssize_t n;
    do {
        n = recv((int)fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT);
    } while (n < 0 && errno == EINTR);
    if (n > 0)
        return 0;
    if (n == 0)
        return 1;
    return (errno == EAGAIN || errno == EWOULDBLOCK) ? 0 : 1;
#endif
}

long kiln_peer_closed_uses_rdhup(void) {
#ifdef POLLRDHUP
    return 1;
#else
    return 0;
#endif
}
