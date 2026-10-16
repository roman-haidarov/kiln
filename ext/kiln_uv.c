#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <arpa/inet.h>
#include <signal.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include "kiln_ascii.h"
#include "libuv/uv.h"

#ifdef SP_THREADS
extern __thread int sp_ffi_bin_len;
#else
extern int sp_ffi_bin_len;
#endif

long kiln_scan_request_head(const char *buf, long len, int64_t *out, long cap);

#define KUV_MAX_SLOTS         65536
#define KUV_HEAD_MAX          16384
#define KUV_SCAN_CAP          (5 + 5 * 100)
#define KUV_CONTENT_LENGTH    6
#define KUV_TRANSFER_ENCODING 23
#define KUV_CONNECTION        5
#define KUV_EXPECT            24
#define KUV_WRITEV_MIN        4096
#define KUV_PIPELINE_MAX      16

static __thread sigset_t kuv_old_sigmask;
static __thread int kuv_sigpipe_blocked;

long kiln_uv_sigpipe_enter(void) {
    sigset_t set;
    sigemptyset(&set);
    sigaddset(&set, SIGPIPE);
    int rc = pthread_sigmask(SIG_BLOCK, &set, &kuv_old_sigmask);
    if (rc == 0)
        kuv_sigpipe_blocked = 1;
    return rc;
}

long kiln_uv_sigpipe_leave(void) {
    if (!kuv_sigpipe_blocked)
        return 0;
    sigset_t pending;
    sigpending(&pending);
    if (sigismember(&pending, SIGPIPE) == 1) {
        sigset_t set;
        sigemptyset(&set);
        sigaddset(&set, SIGPIPE);
        int signal_number;
        sigwait(&set, &signal_number);
    }
    kuv_sigpipe_blocked = 0;
    return pthread_sigmask(SIG_SETMASK, &kuv_old_sigmask, NULL);
}

typedef struct kuv_conn {
    uv_tcp_t tcp;
    uint32_t slot;
    uint32_t gen;
    char *in;
    size_t in_len;
    size_t in_cap;
    char *out;
    size_t out_len;
    size_t out_cap;
    int closing;
    int close_after_flush;
    int queued_flush;
    int pending;
    int awaiting;
    int writes;
    int stop_parse;
    int want_continue;
    int continue_sent;
    int read_paused;
    int read_eof;
    const char *deferred_error;
    long drain_remaining;
    uint64_t last_active;
    uint64_t write_started;
    size_t sending;
} kuv_conn;

typedef struct kuv_req {
    uint32_t slot;
    uint32_t gen;
    long len;
    long nheaders;
    long body_start;
    long body_len;
    char *data;
    int64_t *scan;
    struct kuv_req *next;
} kuv_req;

typedef struct kuv_write {
    uv_write_t req;
    kuv_conn *conn;
    char *data;
    size_t len;
} kuv_write;

static uv_loop_t *kuv_loop;
static uv_tcp_t kuv_server;
static uv_timer_t kuv_timer;
static uv_async_t kuv_wakeup;
static kuv_conn *kuv_slots[KUV_MAX_SLOTS];
static uint32_t kuv_gens[KUV_MAX_SLOTS];
static uint32_t kuv_free[KUV_MAX_SLOTS];
static long kuv_free_count;
static long kuv_open;
static long kuv_max_conns;
static long kuv_max_body;
static uint64_t kuv_idle_ms;
static uint64_t kuv_write_ms;
static kuv_req *kuv_head;
static kuv_req *kuv_tail;
static long kuv_ready;
static long kuv_aborted;
static kuv_req *kuv_current;
static kuv_conn **kuv_flush_list;
static long kuv_flush_count;
static long kuv_flush_cap;
static int kuv_listening;
static int kuv_draining;

static const char KUV_400[] =
    "HTTP/1.1 400 Bad Request\r\nContent-Length: 12\r\nConnection: close\r\n\r\nbad request\n";
static const char KUV_413[] = "HTTP/1.1 413 Content Too Large\r\nContent-Length: 18\r\nConnection: "
                              "close\r\n\r\npayload too large\n";
static const char KUV_431[] = "HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Length: "
                              "17\r\nConnection: close\r\n\r\nheader too large\n";
static const char KUV_501[] = "HTTP/1.1 501 Not Implemented\r\nContent-Length: 16\r\nConnection: "
                              "close\r\n\r\nnot implemented\n";
static const char KUV_417[] = "HTTP/1.1 417 Expectation Failed\r\nContent-Length: "
                              "19\r\nConnection: close\r\n\r\nexpectation failed\n";
static const char KUV_CONTINUE[] = "HTTP/1.1 100 Continue\r\n\r\n";
static const char KUV_503[] =
    "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 5\r\nConnection: close\r\n\r\nbusy\n";

static void kuv_on_close(uv_handle_t *handle) {
    kuv_conn *c = (kuv_conn *)handle->data;
    kuv_slots[c->slot] = NULL;
    kuv_gens[c->slot]++;
    kuv_free[kuv_free_count++] = c->slot;
    __atomic_sub_fetch(&kuv_open, 1, __ATOMIC_RELAXED);
    free(c->in);
    free(c->out);
    free(c);
}

static void kuv_close(kuv_conn *c) {
    if (c->closing)
        return;
    c->closing = 1;
    uv_close((uv_handle_t *)&c->tcp, kuv_on_close);
}

static void kuv_discard_setup_handles(int close_timer, int close_async) {
    if (close_timer)
        uv_close((uv_handle_t *)&kuv_timer, NULL);
    if (close_async)
        uv_close((uv_handle_t *)&kuv_wakeup, NULL);
    uv_close((uv_handle_t *)&kuv_server, NULL);
    uv_run(kuv_loop, UV_RUN_NOWAIT);
}

static void kuv_queue_flush(kuv_conn *c) {
    if (c->queued_flush)
        return;
    if (kuv_flush_count == kuv_flush_cap) {
        long cap = kuv_flush_cap ? kuv_flush_cap * 2 : 64;
        void *raw = realloc((void *)kuv_flush_list, sizeof(kuv_conn *) * (size_t)cap);
        kuv_conn **grown = (kuv_conn **)raw;
        if (!grown) {
            kuv_close(c);
            return;
        }
        kuv_flush_list = grown;
        kuv_flush_cap = cap;
    }
    c->queued_flush = 1;
    kuv_flush_list[kuv_flush_count++] = c;
}

static int kuv_reserve(char **buf, size_t len, size_t *cap, size_t n) {
    if (len + n <= *cap)
        return 0;
    size_t want = *cap ? *cap : 4096;
    while (want < len + n)
        want *= 2;
    char *grown = realloc(*buf, want);
    if (!grown)
        return -1;
    *buf = grown;
    *cap = want;
    return 0;
}

static int kuv_append(char **buf, size_t *len, size_t *cap, const char *data, size_t n) {
    if (kuv_reserve(buf, *len, cap, n) < 0)
        return -1;
    memcpy(*buf + *len, data, n);
    *len += n;
    return 0;
}

static int kuv_append_pair(
    kuv_conn *c, const char *head, size_t head_len, const char *body, size_t body_len) {
    if (kuv_reserve(&c->out, c->out_len, &c->out_cap, head_len + body_len) < 0)
        return -1;
    memcpy(c->out + c->out_len, head, head_len);
    c->out_len += head_len;
    if (body_len > 0) {
        memcpy(c->out + c->out_len, body, body_len);
        c->out_len += body_len;
    }
    return 0;
}

static void kuv_reply_and_close(kuv_conn *c, const char *msg) {
    if (kuv_append(&c->out, &c->out_len, &c->out_cap, msg, strlen(msg)) < 0) {
        kuv_close(c);
        return;
    }
    c->close_after_flush = 1;
    c->stop_parse = 1;
    kuv_queue_flush(c);
}

static void kuv_error(kuv_conn *c, const char *msg) {
    if (c->pending > 0 || c->awaiting > 0) {
        c->deferred_error = msg;
        c->stop_parse = 1;
        uv_read_stop((uv_stream_t *)&c->tcp);
        return;
    }
    kuv_reply_and_close(c, msg);
}

static void kuv_maybe_continue(kuv_conn *c) {
    if (!c->want_continue || c->continue_sent || c->pending > 0 || c->awaiting > 0 || c->closing)
        return;
    if (kuv_append(&c->out, &c->out_len, &c->out_cap, KUV_CONTINUE, sizeof(KUV_CONTINUE) - 1) < 0) {
        kuv_close(c);
        return;
    }
    c->continue_sent = 1;
    kuv_queue_flush(c);
}

static int kuv_has_token(const char *s, long len, const char *token) {
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

static long kuv_digits(const char *s, long len, long *value) {
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

static size_t kuv_align8(size_t n) {
    return (n + 7U) & ~(size_t)7U;
}

static kuv_req *kuv_req_make(const char *bytes, size_t total, const int64_t *scan, long nheaders,
    uint32_t slot, uint32_t gen, long head_len, long body_len) {
    size_t nscan = (size_t)(5 + 5 * nheaders);
    size_t scan_off = kuv_align8(sizeof(kuv_req));
    size_t data_off = scan_off + nscan * sizeof(int64_t);
    if (total > SIZE_MAX - data_off)
        return NULL;
    unsigned char *block = malloc(data_off + total);
    if (!block)
        return NULL;
    kuv_req *r = (kuv_req *)block;
    r->slot = slot;
    r->gen = gen;
    r->len = (long)total;
    r->nheaders = nheaders;
    r->body_start = head_len + 4;
    r->body_len = body_len;
    r->next = NULL;
    r->scan = (int64_t *)(block + scan_off);
    r->data = (char *)(block + data_off);
    memcpy(r->scan, scan, nscan * sizeof(int64_t));
    memcpy(r->data, bytes, total);
    return r;
}

static void kuv_parse(kuv_conn *c) {
    size_t pos = 0;
    while (!c->close_after_flush && !c->stop_parse && pos < c->in_len) {
        if (c->pending + c->awaiting >= KUV_PIPELINE_MAX) {
            c->read_paused = 1;
            uv_read_stop((uv_stream_t *)&c->tcp);
            break;
        }
        char *start = c->in + pos;
        size_t avail = c->in_len - pos;
        const char *end = memmem(start, avail, "\r\n\r\n", 4);
        if (!end) {
            if (avail > KUV_HEAD_MAX)
                kuv_error(c, KUV_431);
            break;
        }
        long head_len = (long)(end - start);
        if (head_len > KUV_HEAD_MAX) {
            kuv_error(c, KUV_431);
            break;
        }
        int64_t scan[KUV_SCAN_CAP];
        long n = kiln_scan_request_head(start, head_len, scan, KUV_SCAN_CAP);
        if (n < 0) {
            kuv_error(c, KUV_400);
            break;
        }
        long body = 0;
        int bad = 0;
        int minor = (int)(scan[4] & 1);
        int has_close = 0;
        int has_keep = 0;
        int expect_continue = 0;
        for (long i = 0; i < n; i++) {
            const int64_t *h = scan + 5 + 5 * i;
            if (h[4] == KUV_TRANSFER_ENCODING)
                bad = 501;
            else if (h[4] == KUV_CONTENT_LENGTH && kuv_digits(start + h[2], (long)h[3], &body) < 0)
                bad = 400;
            else if (h[4] == KUV_CONNECTION) {
                has_close |= kuv_has_token(start + h[2], (long)h[3], "close");
                has_keep |= kuv_has_token(start + h[2], (long)h[3], "keep-alive");
            } else if (h[4] == KUV_EXPECT) {
                if (h[3] == 12 && kiln_ascii_case_equal(start + h[2], "100-continue", 12))
                    expect_continue = minor == 1;
                else if (h[3] > 0)
                    bad = 417;
            }
        }
        if (!bad && body > kuv_max_body)
            bad = 413;
        if (bad) {
            kuv_error(c, bad == 501   ? KUV_501
                         : bad == 413 ? KUV_413
                         : bad == 417 ? KUV_417
                                      : KUV_400);
            break;
        }
        size_t total = (size_t)head_len + 4 + (size_t)body;
        if (avail < total) {
            if (expect_continue) {
                c->want_continue = 1;
                kuv_maybe_continue(c);
            }
            break;
        }
        kuv_req *r = kuv_req_make(start, total, scan, n, c->slot, c->gen, head_len, body);
        if (!r) {
            kuv_close(c);
            return;
        }
        if (kuv_tail)
            kuv_tail->next = r;
        else
            kuv_head = r;
        kuv_tail = r;
        kuv_ready++;
        c->pending++;
        c->want_continue = 0;
        c->continue_sent = 0;
        pos += total;
        if (has_close || (minor == 0 && !has_keep)) {
            c->stop_parse = 1;
            uv_read_stop((uv_stream_t *)&c->tcp);
        }
    }
    if (c->stop_parse) {
        c->in_len = 0;
        return;
    }
    if (pos > 0) {
        memmove(c->in, c->in + pos, c->in_len - pos);
        c->in_len -= pos;
    }
}

static void kuv_alloc(uv_handle_t *handle, size_t suggested, uv_buf_t *buf) {
    kuv_conn *c = (kuv_conn *)handle->data;
    (void)suggested;
    if (c->in_cap - c->in_len < 16384) {
        size_t want = c->in_cap ? c->in_cap * 2 : 32768;
        char *grown = realloc(c->in, want);
        if (!grown) {
            buf->base = NULL;
            buf->len = 0;
            return;
        }
        c->in = grown;
        c->in_cap = want;
    }
    buf->base = c->in + c->in_len;
    buf->len = c->in_cap - c->in_len;
}

static void kuv_on_read_end(kuv_conn *c) {
    c->read_eof = 1;
    uv_read_stop((uv_stream_t *)&c->tcp);
    if (!c->stop_parse && !c->closing)
        kuv_parse(c);
    if (c->closing)
        return;
    if (c->read_paused && c->in_len > 0 && !c->stop_parse)
        return;
    c->stop_parse = 1;
    c->read_paused = 0;
    c->in_len = 0;
    if (c->pending > 0 || c->awaiting > 0)
        return;
    if (c->deferred_error) {
        const char *error = c->deferred_error;
        c->deferred_error = NULL;
        kuv_reply_and_close(c, error);
        return;
    }
    c->close_after_flush = 1;
    if (c->out_len > 0)
        kuv_queue_flush(c);
    else if (c->writes == 0)
        kuv_close(c);
}

static void kuv_on_read(uv_stream_t *stream, ssize_t nread, const uv_buf_t *buf) {
    kuv_conn *c = (kuv_conn *)stream->data;
    (void)buf;
    if (nread < 0) {
        kuv_on_read_end(c);
        return;
    }
    if (nread == 0)
        return;
    c->in_len += (size_t)nread;
    c->last_active = uv_now(kuv_loop);
    kuv_parse(c);
}

static void kuv_on_connection(uv_stream_t *server, int status) {
    if (status < 0)
        return;
    kuv_conn *c = calloc(1, sizeof(kuv_conn));
    if (!c)
        return;
    uv_tcp_init(kuv_loop, &c->tcp);
    if (uv_accept(server, (uv_stream_t *)&c->tcp) != 0 || kuv_free_count == 0) {
        uv_close((uv_handle_t *)&c->tcp, (uv_close_cb)free);
        return;
    }
    c->slot = kuv_free[--kuv_free_count];
    c->gen = kuv_gens[c->slot];
    c->tcp.data = c;
    c->last_active = uv_now(kuv_loop);
    kuv_slots[c->slot] = c;
    long open = __atomic_add_fetch(&kuv_open, 1, __ATOMIC_RELAXED);
    uv_tcp_nodelay(&c->tcp, 1);
    if (open > kuv_max_conns) {
        kuv_reply_and_close(c, KUV_503);
        return;
    }
    uv_read_start((uv_stream_t *)&c->tcp, kuv_alloc, kuv_on_read);
}

static uint64_t kuv_tick_ms(void) {
    uint64_t tick = 1000;
    if (kuv_idle_ms < tick)
        tick = kuv_idle_ms;
    if (kuv_write_ms < tick)
        tick = kuv_write_ms;
    return tick < 1 ? 1 : tick;
}

static void kuv_on_timer(uv_timer_t *timer) {
    (void)timer;
    uint64_t now = uv_now(kuv_loop);
    for (long i = 0; i < KUV_MAX_SLOTS; i++) {
        kuv_conn *c = kuv_slots[i];
        if (!c || c->closing)
            continue;
        if (c->writes > 0) {
            if (kuv_write_ms > 0 && now - c->write_started > kuv_write_ms)
                kuv_close(c);
        } else if (c->pending == 0 && c->awaiting == 0 && now - c->last_active > kuv_idle_ms) {
            kuv_close(c);
        }
    }
}

static int kuv_parse_addr(const char *host, int port, struct sockaddr_storage *addr) {
    if (uv_ip4_addr(host, port, (struct sockaddr_in *)addr) == 0)
        return 0;
    return uv_ip6_addr(host, port, (struct sockaddr_in6 *)addr);
}

long kiln_uv_listen(
    const char *host, long port, long max_conns, long max_body, long idle_ms, long write_ms) {
    struct sockaddr_storage addr;
    if (kuv_listening)
        return UV_EALREADY;
    kuv_loop = uv_default_loop();
    kuv_max_conns = max_conns;
    kuv_max_body = max_body;
    kuv_idle_ms = (uint64_t)idle_ms;
    if (write_ms < 1)
        write_ms = 1;
    kuv_write_ms = (uint64_t)write_ms;
    kuv_free_count = 0;
    kuv_aborted = 0;
    for (long i = KUV_MAX_SLOTS - 1; i >= 0; i--)
        kuv_free[kuv_free_count++] = (uint32_t)i;
    int rc = kuv_parse_addr(host, (int)port, &addr);
    if (rc != 0)
        return rc;
    rc = uv_tcp_init(kuv_loop, &kuv_server);
    if (rc != 0)
        return rc;
    rc = uv_tcp_bind(&kuv_server, (const struct sockaddr *)&addr, 0);
    if (rc != 0) {
        kuv_discard_setup_handles(0, 0);
        return rc;
    }
    rc = uv_listen((uv_stream_t *)&kuv_server, 1024, kuv_on_connection);
    if (rc != 0) {
        kuv_discard_setup_handles(0, 0);
        return rc;
    }
    rc = uv_async_init(kuv_loop, &kuv_wakeup, NULL);
    if (rc != 0) {
        kuv_discard_setup_handles(0, 0);
        return rc;
    }
    rc = uv_timer_init(kuv_loop, &kuv_timer);
    if (rc != 0) {
        kuv_discard_setup_handles(0, 1);
        return rc;
    }
    uint64_t tick = kuv_tick_ms();
    rc = uv_timer_start(&kuv_timer, kuv_on_timer, tick, tick);
    if (rc != 0) {
        kuv_discard_setup_handles(1, 1);
        return rc;
    }
    kuv_listening = 1;
    return 0;
}

long kiln_uv_running(void) {
    return kuv_listening;
}

const char *kiln_uv_error_text(long code) {
    const char *message = uv_strerror((int)code);
    sp_ffi_bin_len = (int)strlen(message);
    return message;
}

long kiln_uv_port(void) {
    struct sockaddr_storage addr;
    int len = sizeof(addr);
    if (uv_tcp_getsockname(&kuv_server, (struct sockaddr *)&addr, &len) != 0)
        return -1;
    if (addr.ss_family == AF_INET6)
        return ntohs(((struct sockaddr_in6 *)&addr)->sin6_port);
    return ntohs(((struct sockaddr_in *)&addr)->sin_port);
}

long kiln_uv_fd(void) {
    return uv_backend_fd(kuv_loop);
}

long kiln_uv_poll(void) {
    uv_run(kuv_loop, UV_RUN_NOWAIT);
    return kuv_ready;
}

const char *kiln_uv_next(int64_t *scan, long cap, int64_t *meta) {
    if (kuv_current) {
        free(kuv_current);
        kuv_current = NULL;
    }
    while (kuv_head && cap >= KUV_SCAN_CAP) {
        kuv_req *r = kuv_head;
        kuv_head = r->next;
        if (!kuv_head)
            kuv_tail = NULL;
        kuv_ready--;
        kuv_conn *c = kuv_slots[r->slot];
        int live = c && c->gen == r->gen;
        if (live)
            c->pending--;
        if (!live || c->closing || c->close_after_flush) {
            if (kuv_draining)
                kuv_aborted++;
            free(r);
            continue;
        }
        c->awaiting++;
        kuv_current = r;
        memcpy(scan, r->scan, sizeof(int64_t) * (size_t)(5 + 5 * r->nheaders));
        meta[0] = r->nheaders;
        meta[1] = r->body_start;
        meta[2] = r->body_len;
        meta[3] = r->slot;
        meta[4] = r->gen;
        sp_ffi_bin_len = (int)r->len;
        return r->data;
    }
    sp_ffi_bin_len = 0;
    return "";
}

static void kuv_after_write(uv_write_t *req, int status) {
    kuv_write *w = (kuv_write *)req;
    kuv_conn *c = w->conn;
    c->sending -= w->len;
    free(w->data);
    free(w);
    c->writes--;
    if (c->writes == 0)
        c->write_started = 0;
    if (status < 0 || (c->close_after_flush && c->writes == 0 && c->out_len == 0))
        kuv_close(c);
}

static int kuv_queue_owned(kuv_conn *c, char *data, size_t len) {
    kuv_write *w = malloc(sizeof(*w));
    if (!w) {
        free(data);
        return -1;
    }
    w->conn = c;
    w->data = data;
    w->len = len;
    uv_buf_t wb = uv_buf_init(data, (unsigned int)len);
    if (c->writes++ == 0)
        c->write_started = uv_now(kuv_loop);
    if (uv_write(&w->req, (uv_stream_t *)&c->tcp, &wb, 1, kuv_after_write) != 0) {
        c->writes--;
        if (c->writes == 0)
            c->write_started = 0;
        free(data);
        free(w);
        return -1;
    }
    c->sending += len;
    return 0;
}

static char *kuv_unsent(const char *head, size_t head_len, const char *body, size_t body_len,
    size_t done, size_t *rest_out) {
    size_t total = head_len + body_len;
    if (done >= total) {
        *rest_out = 0;
        return NULL;
    }
    size_t rest = total - done;
    *rest_out = rest;
    char *copy = malloc(rest);
    if (!copy)
        return NULL;
    size_t filled = 0;
    if (done < head_len) {
        size_t n = head_len - done;
        memcpy(copy, head + done, n);
        filled = n;
        done = 0;
    } else {
        done -= head_len;
    }
    if (done < body_len)
        memcpy(copy + filled, body + done, body_len - done);
    return copy;
}

static int kuv_writev_now(
    kuv_conn *c, const char *head, size_t head_len, const char *body, size_t body_len) {
    uv_buf_t bufs[2];
    unsigned int nbufs = 0;
    if (head_len > 0)
        bufs[nbufs++] = uv_buf_init((char *)head, (unsigned int)head_len);
    if (body_len > 0)
        bufs[nbufs++] = uv_buf_init((char *)body, (unsigned int)body_len);
    if (nbufs == 0)
        return 0;
    int done = uv_try_write((uv_stream_t *)&c->tcp, bufs, nbufs);
    if (done < 0 && done != UV_EAGAIN)
        return -1;
    if (done <= 0)
        return 1;
    size_t rest = 0;
    char *copy = kuv_unsent(head, head_len, body, body_len, (size_t)done, &rest);
    if (rest == 0)
        return 0;
    if (!copy || kuv_queue_owned(c, copy, rest) < 0)
        return -1;
    return 0;
}

static int kuv_try_direct(
    kuv_conn *c, const char *head, size_t head_len, const char *body, size_t body_len) {
    if (body_len < KUV_WRITEV_MIN || c->out_len != 0 || c->writes != 0)
        return 1;
    int wr = kuv_writev_now(c, head, head_len, body, body_len);
    if (wr < 0) {
        kuv_close(c);
        return -1;
    }
    return wr == 0 ? 0 : 1;
}

static void kuv_send_finish(kuv_conn *c, long close_after) {
    int hit_zero = 0;
    if (c->read_paused && !c->stop_parse && !kuv_draining) {
        c->read_paused = 0;
        kuv_parse(c);
        if (!c->read_paused && !c->stop_parse && !c->closing && !c->read_eof)
            uv_read_start((uv_stream_t *)&c->tcp, kuv_alloc, kuv_on_read);
    }
    if (c->deferred_error && c->pending == 0 && c->awaiting == 0) {
        const char *error = c->deferred_error;
        c->deferred_error = NULL;
        if (!kuv_draining)
            kuv_reply_and_close(c, error);
    }
    if (c->read_eof && c->pending == 0 && c->awaiting == 0)
        close_after = 1;
    if (!close_after && kuv_draining && c->drain_remaining > 0) {
        c->drain_remaining--;
        hit_zero = c->drain_remaining == 0;
    }
    if (close_after || hit_zero) {
        c->close_after_flush = 1;
        c->stop_parse = 1;
        uv_read_stop((uv_stream_t *)&c->tcp);
    }
    c->last_active = uv_now(kuv_loop);
    if (c->out_len > 0)
        kuv_queue_flush(c);
    else if (c->close_after_flush && c->writes == 0)
        kuv_close(c);
    kuv_maybe_continue(c);
}

long kiln_uv_send(long slot, long gen, const char *head, long head_len, const char *body,
    long body_len, long close_after) {
    if (slot < 0 || slot >= KUV_MAX_SLOTS || head_len < 0 || body_len < 0)
        return -1;
    kuv_conn *c = kuv_slots[slot];
    if (!c || c->gen != (uint32_t)gen || c->closing || c->close_after_flush)
        return -1;
    if (c->awaiting > 0)
        c->awaiting--;
    int append = kuv_try_direct(c, head, (size_t)head_len, body, (size_t)body_len);
    if (append < 0)
        return -1;
    if (append && kuv_append_pair(c, head, (size_t)head_len, body, (size_t)body_len) < 0) {
        kuv_close(c);
        return -1;
    }
    kuv_send_finish(c, close_after);
    return 0;
}

static kuv_conn *kuv_live(long slot, long gen) {
    if (slot < 0 || slot >= KUV_MAX_SLOTS)
        return NULL;
    kuv_conn *c = kuv_slots[slot];
    if (!c || c->gen != (uint32_t)gen || c->closing || c->close_after_flush)
        return NULL;
    return c;
}

long kiln_uv_part(long slot, long gen, const char *data, long len) {
    kuv_conn *c = kuv_live(slot, gen);
    if (!c || len < 0)
        return -1;
    if (len > 0) {
        if (kuv_append(&c->out, &c->out_len, &c->out_cap, data, (size_t)len) < 0) {
            kuv_close(c);
            return -1;
        }
        c->last_active = uv_now(kuv_loop);
        kuv_queue_flush(c);
    }
    return (long)(c->out_len + c->sending);
}

long kiln_uv_backlog(long slot, long gen) {
    const kuv_conn *c = kuv_live(slot, gen);
    return c ? (long)(c->out_len + c->sending) : -1;
}

long kiln_uv_abort(long slot, long gen) {
    if (slot < 0 || slot >= KUV_MAX_SLOTS)
        return -1;
    kuv_conn *c = kuv_slots[slot];
    if (!c || c->gen != (uint32_t)gen || c->closing)
        return -1;
    if (c->awaiting > 0)
        c->awaiting--;
    c->stop_parse = 1;
    c->close_after_flush = 1;
    uv_read_stop((uv_stream_t *)&c->tcp);
    if (c->out_len > 0)
        kuv_queue_flush(c);
    else if (c->writes == 0)
        kuv_close(c);
    return 0;
}

long kiln_uv_closes_after(long slot, long gen, long stopping) {
    if (slot < 0 || slot >= KUV_MAX_SLOTS)
        return 1;
    const kuv_conn *c = kuv_slots[slot];
    if (!c || c->gen != (uint32_t)gen || c->closing || c->close_after_flush)
        return 1;
    if (kuv_draining)
        return c->drain_remaining == 1;
    return stopping && c->pending == 0 && c->awaiting == 1;
}

long kiln_uv_flush(void) {
    long flushed = kuv_flush_count;
    for (long i = 0; i < kuv_flush_count; i++) {
        kuv_conn *c = kuv_flush_list[i];
        c->queued_flush = 0;
        if (c->closing)
            continue;
        if (c->out_len > 0) {
            uv_buf_t b = uv_buf_init(c->out, (unsigned int)c->out_len);
            int done = c->writes == 0 ? uv_try_write((uv_stream_t *)&c->tcp, &b, 1) : 0;
            if (done < 0 && done != UV_EAGAIN) {
                c->out_len = 0;
                kuv_close(c);
                continue;
            }
            if (done < 0)
                done = 0;
            size_t rest = c->out_len - (size_t)done;
            if (rest > 0) {
                kuv_write *w = malloc(sizeof(kuv_write));
                if (!w) {
                    c->out_len = 0;
                    kuv_close(c);
                    continue;
                }
                w->conn = c;
                w->data = c->out;
                w->len = rest;
                uv_buf_t wb = uv_buf_init(c->out + done, (unsigned int)rest);
                c->out = NULL;
                c->out_cap = 0;
                if (c->writes++ == 0)
                    c->write_started = uv_now(kuv_loop);
                if (uv_write(&w->req, (uv_stream_t *)&c->tcp, &wb, 1, kuv_after_write) != 0) {
                    c->writes--;
                    if (c->writes == 0)
                        c->write_started = 0;
                    free(w->data);
                    free(w);
                    c->out_len = 0;
                    kuv_close(c);
                    continue;
                }
                c->sending += rest;
            }
            c->out_len = 0;
        }
        if (c->close_after_flush && c->writes == 0)
            kuv_close(c);
    }
    kuv_flush_count = 0;
    return flushed;
}

long kiln_uv_open(void) {
    return __atomic_load_n(&kuv_open, __ATOMIC_RELAXED);
}

long kiln_uv_aborted(void) {
    return kuv_aborted;
}

long kiln_uv_stop(void) {
    if (!kuv_listening)
        return 0;
    uv_close((uv_handle_t *)&kuv_wakeup, NULL);
    uv_timer_stop(&kuv_timer);
    uv_close((uv_handle_t *)&kuv_timer, NULL);
    if (!kuv_draining)
        uv_close((uv_handle_t *)&kuv_server, NULL);
    for (long i = 0; i < KUV_MAX_SLOTS; i++)
        if (kuv_slots[i])
            kuv_close(kuv_slots[i]);
    kuv_aborted += kuv_ready;
    uv_run(kuv_loop, UV_RUN_NOWAIT);
    while (kuv_head) {
        kuv_req *r = kuv_head;
        kuv_head = r->next;
        free(r);
    }
    kuv_tail = NULL;
    kuv_ready = 0;
    if (kuv_current) {
        free(kuv_current);
        kuv_current = NULL;
    }
    kuv_flush_count = 0;
    kuv_listening = 0;
    kuv_draining = 0;
    return 0;
}

long kiln_uv_wake(void) {
    return uv_async_send(&kuv_wakeup);
}

long kiln_uv_drain(void) {
    if (!kuv_listening || kuv_draining)
        return 0;
    kuv_draining = 1;
    uv_close((uv_handle_t *)&kuv_server, NULL);
    for (long i = 0; i < KUV_MAX_SLOTS; i++) {
        kuv_conn *c = kuv_slots[i];
        if (!c || c->closing)
            continue;
        c->drain_remaining = c->pending + c->awaiting;
        c->stop_parse = 1;
        c->in_len = 0;
        uv_read_stop((uv_stream_t *)&c->tcp);
        if (c->drain_remaining == 0) {
            c->close_after_flush = 1;
            if (c->out_len > 0)
                kuv_queue_flush(c);
            else if (c->writes == 0)
                kuv_close(c);
        }
    }
    return 0;
}

static int kuv_idle(const kuv_conn *c) {
    return c->pending == 0 && c->awaiting == 0 && c->out_len == 0 && c->writes == 0;
}

long kiln_uv_busy(void) {
    long busy = kuv_ready;
    for (long i = 0; i < KUV_MAX_SLOTS; i++) {
        kuv_conn *c = kuv_slots[i];
        if (!c || c->closing)
            continue;
        if (!kuv_idle(c))
            busy++;
        else if (kuv_draining)
            kuv_close(c);
    }
    return busy;
}
