#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <stdint.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include "kiln_ascii.h"
#include "picohttpparser/picohttpparser.h"

#define KILN_MAX_HEAD    16384
#define KILN_MAX_HEADERS 100
#define KILN_STRIDE      5
#define KILN_RECV_MAX    16384

static void kiln_free_components(char *copy, const char *local) {
    if (copy != local)
        free(copy);
}

static long kiln_open_components(int current, int owned, const char *path, long len) {
    if (len == 0)
        return current;
    char local[256];
    char *copy = (size_t)len >= sizeof(local) ? malloc((size_t)len + 1) : local;
    if (!copy) {
        if (owned)
            close(current);
        return -1;
    }
    memcpy(copy, path, (size_t)len);
    copy[len] = '\0';
    char *segment = copy;
    while (segment) {
        char *slash = strchr(segment, '/');
        if (slash)
            *slash = '\0';
        if (!*segment || strcmp(segment, ".") == 0 || strcmp(segment, "..") == 0)
            break;
        int flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK;
        if (slash)
            flags |= O_DIRECTORY;
        int next = openat(current, segment, flags);
        if (owned)
            close(current);
        current = next;
        owned = next >= 0;
        if (next < 0)
            break;
        if (!slash) {
            kiln_free_components(copy, local);
            return current;
        }
        segment = slash + 1;
    }
    kiln_free_components(copy, local);
    if (owned)
        close(current);
    return -1;
}

static long kiln_skip_ows(const unsigned char *value, long index, long limit) {
    while (index < limit && (value[index] == ' ' || value[index] == '\t'))
        index++;
    return index;
}

static long kiln_trim_ows(const unsigned char *value, long start, long limit) {
    while (limit > start && (value[limit - 1] == ' ' || value[limit - 1] == '\t'))
        limit--;
    return limit;
}

static int kiln_quality(const unsigned char *value, long start, long limit) {
    long length = limit - start;
    if (length == 1) {
        if (value[start] == '1')
            return 1;
        return value[start] == '0' ? 0 : -1;
    }
    if (length < 2 || length > 5)
        return -1;
    if (value[start + 1] != '.')
        return -1;
    unsigned char first = value[start];
    if (first != '0' && first != '1')
        return -1;
    int positive = first == '1';
    for (long i = start + 2; i < limit; i++) {
        unsigned char digit = value[i];
        if (digit < '0' || digit > '9' || (first == '1' && digit != '0'))
            return -1;
        positive |= digit != '0';
    }
    return first == '1' || positive;
}

static int kiln_gzip_kind(const unsigned char *value, long start, long limit) {
    long length = limit - start;
    if ((length == 4 && kiln_ascii_case_equal((const char *)value + start, "gzip", 4)) ||
        (length == 6 && kiln_ascii_case_equal((const char *)value + start, "x-gzip", 6)))
        return 1;
    return length == 1 && value[start] == '*' ? 2 : 0;
}

static int kiln_accept_parameters(
    const unsigned char *value, long start, long size, long *next_start, int *quality) {
    int valid = 1;
    long param_start = start;
    while (param_start < size && value[param_start] != ',') {
        if (value[param_start] == ';')
            param_start++;
        long param_end = param_start;
        while (param_end < size && value[param_end] != ';' && value[param_end] != ',')
            param_end++;
        long equals = param_start;
        while (equals < param_end && value[equals] != '=')
            equals++;
        long key_start = kiln_skip_ows(value, param_start, equals);
        long key_end = kiln_trim_ows(value, key_start, equals);
        if (key_end - key_start == 1 && (value[key_start] == 'q' || value[key_start] == 'Q')) {
            if (equals == param_end) {
                valid = 0;
            } else {
                long q_start = kiln_skip_ows(value, equals + 1, param_end);
                long q_end = kiln_trim_ows(value, q_start, param_end);
                int parsed = kiln_quality(value, q_start, q_end);
                if (parsed < 0)
                    valid = 0;
                else
                    *quality = parsed;
            }
        }
        param_start = param_end;
    }
    *next_start = param_start + 1;
    return valid;
}

long kiln_http_accepts_gzip(const char *text, long len) {
    if (!text || len <= 0)
        return 0;
    const unsigned char *value = (const unsigned char *)text;
    int star = 0;
    long size = len;
    long part_start = 0;
    while (part_start < size) {
        long token_end = part_start;
        while (token_end < size && value[token_end] != ';' && value[token_end] != ',')
            token_end++;
        long token_start = kiln_skip_ows(value, part_start, token_end);
        long token_limit = kiln_trim_ows(value, token_start, token_end);
        int kind = kiln_gzip_kind(value, token_start, token_limit);
        int quality = 1;
        long next_start;
        int valid = kiln_accept_parameters(value, token_end, size, &next_start, &quality);
        if (valid) {
            if (kind == 1)
                return quality;
            if (kind == 2)
                star = quality;
        }
        part_start = next_start;
    }
    return star;
}

long kiln_http_open_beneath(long base_fd, const char *path, long len) {
    if (!path || len < 0 || memchr(path, '\0', (size_t)len))
        return -1;
    if (base_fd < 0) {
        if (len == 0 || path[0] != '/')
            return -1;
        int root = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
        if (root < 0)
            return -1;
        return kiln_open_components(root, 1, path + 1, len - 1);
    }
    if (len == 0 || path[0] == '/')
        return -1;
    return kiln_open_components((int)base_fd, 0, path, len);
}

#ifdef SP_THREADS
extern __thread int sp_ffi_bin_len;
static __thread char kiln_rbuf[KILN_RECV_MAX];
static __thread long kiln_rstatus;
#else
extern int sp_ffi_bin_len;
static char kiln_rbuf[KILN_RECV_MAX];
static long kiln_rstatus;
#endif

static const char *const kiln_common[] = {"host", "user-agent", "accept", "accept-encoding",
    "accept-language", "connection", "content-length", "content-type", "cookie", "referer",
    "cache-control", "upgrade-insecure-requests", "sec-fetch-site", "sec-fetch-mode",
    "sec-fetch-user", "sec-fetch-dest", "sec-ch-ua", "sec-ch-ua-mobile", "sec-ch-ua-platform",
    "origin", "authorization", "if-none-match", "if-modified-since", "transfer-encoding", "expect",
    "x-forwarded-for", "x-request-id", "pragma", "priority", "te", "range", "dnt"};

static const uint8_t kiln_common_lengths[] = {4, 10, 6, 15, 15, 10, 14, 12, 6, 7, 13, 25, 14, 14,
    14, 14, 9, 16, 18, 6, 13, 13, 17, 17, 6, 15, 12, 6, 8, 2, 5, 3};

static const uint8_t kiln_common_slots[256] = {[20] = 1,
    [1] = 2,
    [154] = 3,
    [192] = 4,
    [235] = 5,
    [78] = 6,
    [142] = 7,
    [10] = 8,
    [216] = 9,
    [215] = 10,
    [48] = 11,
    [68] = 12,
    [74] = 13,
    [174] = 14,
    [190] = 15,
    [185] = 16,
    [38] = 17,
    [3] = 18,
    [150] = 19,
    [236] = 20,
    [163] = 21,
    [238] = 22,
    [0] = 23,
    [113] = 24,
    [223] = 25,
    [253] = 26,
    [148] = 27,
    [42] = 28,
    [126] = 29,
    [45] = 30,
    [247] = 31,
    [232] = 32};

static long kiln_common_index(const char *name, size_t len) {
    if (len < 2 || len > 25)
        return -1;
    uint32_t hash = 10;
    for (size_t i = 0; i < len; i++)
        hash = (hash ^ ((unsigned char)name[i] | 32U)) * 16777619U;
    uint8_t slot = kiln_common_slots[hash & 255U];
    if (!slot)
        return -1;
    size_t index = (size_t)slot - 1;
    return kiln_common_lengths[index] == len && kiln_ascii_case_equal(kiln_common[index], name, len)
               ? (long)index
               : -1;
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
    int used = phr_parse_request(
        buf, (size_t)len + 4, &method, &method_len, &path, &path_len, &minor, headers, &num, 0);
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
    case '!':
    case '#':
    case '$':
    case '%':
    case '&':
    case '\'':
    case '*':
    case '+':
    case '-':
    case '.':
    case '^':
    case '_':
    case '`':
    case '|':
    case '~':
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
        if (i >= len || s[i] != ';')
            return -1;
        i++;
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

long kiln_peer_closed(long fd);

long kiln_socket_nonblock(long fd) {
    if (fd < 0)
        return -1;
    int flags = fcntl((int)fd, F_GETFL);
    if (flags < 0 || fcntl((int)fd, F_SETFL, flags | O_NONBLOCK) < 0)
        return -1;
    return 0;
}

long kiln_sendv(
    long fd, const char *head, long head_len, const char *body, long body_len, long off) {
    if (head_len < 0 || body_len < 0 || off < 0 || off > head_len + body_len)
        return -2;
    struct iovec iov[2];
    int count = 0;
    if (off < head_len) {
        iov[count].iov_base = (void *)(head + off);
        iov[count].iov_len = (size_t)(head_len - off);
        count++;
        off = 0;
    } else {
        off -= head_len;
    }
    if (off < body_len) {
        iov[count].iov_base = (void *)(body + off);
        iov[count].iov_len = (size_t)(body_len - off);
        count++;
    }
    if (count == 0)
        return 0;
    struct msghdr msg = {0};
    msg.msg_iov = iov;
    msg.msg_iovlen = count;
    ssize_t n;
    do {
        n = sendmsg((int)fd, &msg, MSG_DONTWAIT | MSG_NOSIGNAL);
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

long kiln_scan_request_head(const char *buf, long len, int64_t *out, long cap) {
    return kiln_scan_terminated(buf, len, out, cap, 0);
}
