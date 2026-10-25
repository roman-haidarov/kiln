#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <arpa/inet.h>
#include <limits.h>
#include <signal.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include "kiln_tls.h"
#include "kiln_uv_parse.h"
#include "kiln_uv_state.h"
#include "libuv/include/uv.h"

#ifdef SP_THREADS
extern __thread int sp_ffi_bin_len;
#else
extern int sp_ffi_bin_len;
#endif

long kiln_sock_adopt(long fd);
long kiln_sock_nosigpipe(long fd);

#define KUV_MAX_SLOTS     65536
#define KUV_MAX_LISTENERS 16
#define KUV_WRITEV_MIN    4096
#define KUV_PIPELINE_MAX  16
#define KUV_BODY_HIGH     ((size_t)256 * 1024)
#define KUV_BODY_LOW      ((size_t)64 * 1024)
#define KUV_DRAIN_MAX     (256L * 1024)
#define KUV_OUT_HIGH      ((size_t)256 * 1024)
#define KUV_OUT_LOW       ((size_t)64 * 1024)
#define KUV_TLS_SCRATCH   ((size_t)64 * 1024)
#define KUV_TLS_READ      16384
#define KUV_CONFIG_SIZE   10

enum { KUV_TCP = 1, KUV_UNIX = 2 };
enum { KUV_BODY_NONE, KUV_BODY_LENGTH, KUV_BODY_CHUNKED, KUV_BODY_TUNNEL };
enum { KUV_TAKE_GONE = -1, KUV_TAKE_WAIT = 0, KUV_TAKE_DATA = 1, KUV_TAKE_EOF = 2 };
enum { KUV_GONE = 499 };
enum { KUV_FLAG_STREAMED = 1, KUV_FLAG_CHUNKED = 2, KUV_FLAG_UPGRADE = 4, KUV_FLAG_TLS = 8 };

static __thread sigset_t kuv_old_sigmask;
static __thread int kuv_sigpipe_blocked;

long kiln_uv_sigpipe_enter(void) {
    sigset_t set;
    sigemptyset(&set);
    sigaddset(&set, SIGPIPE);
    int rc = pthread_sigmask(SIG_BLOCK, &set, &kuv_old_sigmask);
    if (rc == 0) {
        kuv_sigpipe_blocked = 1;
    }
    return rc;
}

long kiln_uv_sigpipe_leave(void) {
    if (!kuv_sigpipe_blocked) {
        return 0;
    }
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

typedef union kuv_handle {
    uv_tcp_t tcp;
    uv_pipe_t pipe;
} kuv_handle;

typedef struct kuv_listener {
    kuv_handle h;
    int kind;
    int tls;
    int paused;
    int open;
} kuv_listener;

typedef struct kuv_conn {
    kuv_handle h;
    uv_shutdown_t shut;
    uint32_t slot;
    uint32_t gen;
    int listener;
    kiln_tls_conn *tls;
    char *in;
    size_t in_len;
    size_t in_cap;
    char *out;
    size_t out_len;
    size_t out_cap;
    char *tls_pending;
    size_t tls_pending_len;
    size_t tls_pending_off;
    uint64_t tls_write_since;
    int tls_wait;
    char *body;
    size_t body_len;
    size_t body_cap;
    kiln_uv_chunk_state chunk;
    long body_left;
    long drain_remaining;
    uint64_t last_active;
    uint64_t write_started;
    uint64_t head_since;
    uint64_t linger_since;
    size_t sending;
    const char *deferred_error;
    kuv_conn_state state;
    kuv_parse_state parse_state;
    kuv_body_state body_state;
    kuv_expect_state expect_state;
    kuv_head_state head_state;
    int queued_flush;
    int pending;
    int awaiting;
    int writes;
    int read_paused;
    int read_eof;
    int reading;
    int served;
    int handshaking;
    int body_mode;
    int body_error;
    int body_discard;
    int resume_parse;
    int out_paused;
    int refused;
    size_t head_scanned;
} kuv_conn;

typedef struct kuv_req {
    uint32_t slot;
    uint32_t gen;
    long len;
    long nheaders;
    long body_start;
    long body_len;
    long flags;
    long declared;
    long listener;
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
static kuv_listener kuv_listeners[KUV_MAX_LISTENERS];
static long kuv_listener_count;
static uv_timer_t kuv_timer;
static uv_async_t kuv_wakeup;
static kuv_conn *kuv_slots[KUV_MAX_SLOTS];
static uint32_t kuv_gens[KUV_MAX_SLOTS];
static uint32_t kuv_free[KUV_MAX_SLOTS];
static long kuv_free_count;
static long kuv_open;
static long kuv_max_conns;
static long kuv_buffer_body;
static uint64_t kuv_header_ms;
static uint64_t kuv_keepalive_ms;
static uint64_t kuv_read_ms;
static uint64_t kuv_write_ms;
static uint64_t kuv_linger_ms;
static int kuv_nodelay;
static long kuv_max_handshakes;
static long kuv_handshakes;
static long kuv_backlog;
static kuv_req *kuv_head;
static kuv_req *kuv_tail;
static long kuv_ready;
static long kuv_aborted;
static kuv_req *kuv_current;
static kuv_conn **kuv_flush_list;
static long kuv_flush_count;
static long kuv_flush_cap;
static int kuv_configured;
static int kuv_listening;
static int kuv_draining;
static char kuv_tls_scratch[KUV_TLS_SCRATCH];
static char *kuv_take_buf;
static size_t kuv_take_cap;

static const char KUV_400[] =
    "HTTP/1.1 400 Bad Request\r\nContent-Length: 12\r\nConnection: close\r\n\r\nbad request\n";
static const char KUV_408[] = "HTTP/1.1 408 Request Timeout\r\nContent-Length: 16\r\nConnection: "
                              "close\r\n\r\nrequest timeout\n";
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

static void kuv_accept_one(kuv_listener *l);
long kiln_uv_open(void);
static void kuv_on_read(uv_stream_t *stream, ssize_t nread, const uv_buf_t *buf);
static void kuv_alloc(uv_handle_t *handle, size_t suggested, uv_buf_t *buf);
static void kuv_parse(kuv_conn *c);
static void kuv_flush_tls(kuv_conn *c);

static void kuv_stop_parsing(kuv_conn *c) {
    if (c->parse_state != KUV_PARSE_TUNNEL) {
        c->parse_state = KUV_PARSE_STOPPED;
    }
}

static void kuv_release_upgrade(kuv_conn *c) {
    if (c->parse_state == KUV_PARSE_UPGRADE) {
        c->parse_state = KUV_PARSE_OPEN;
    }
}

static void kuv_body_complete(kuv_conn *c) {
    if (!c->body_error) {
        c->body_state = KUV_BODY_DONE;
    }
}

static void kuv_body_pause(kuv_conn *c) {
    if (c->body_state == KUV_BODY_READING) {
        c->body_state = KUV_BODY_PAUSED;
    }
}

static void kuv_body_resume(kuv_conn *c) {
    if (c->body_state == KUV_BODY_PAUSED) {
        c->body_state = KUV_BODY_READING;
    }
}

static uv_stream_t *kuv_stream(kuv_conn *c) {
    return (uv_stream_t *)&c->h;
}

static size_t kuv_out_bytes(const kuv_conn *c) {
    return c->out_len + c->sending + c->tls_pending_len - c->tls_pending_off;
}

static int kuv_wants_read(const kuv_conn *c) {
    if (c->state == KUV_CONN_CLOSING || c->read_eof) {
        return 0;
    }
    if (c->state == KUV_CONN_LINGERING) {
        return 1;
    }
    if (c->tls_wait == KILN_TLS_WANT_READ) {
        return 1;
    }
    if (c->body_mode != KUV_BODY_NONE) {
        return c->body_state != KUV_BODY_DONE && c->body_state != KUV_BODY_PAUSED && !c->body_error;
    }
    return c->parse_state == KUV_PARSE_OPEN && !c->read_paused && !c->out_paused;
}

static void kuv_sync_read(kuv_conn *c) {
    int want = kuv_wants_read(c);
    if (want && !c->reading) {
        if (uv_read_start(kuv_stream(c), kuv_alloc, kuv_on_read) == 0) {
            c->reading = 1;
        }
    } else if (!want && c->reading) {
        uv_read_stop(kuv_stream(c));
        c->reading = 0;
    }
}

static void kuv_resume_listeners(void) {
    for (long i = 0; i < kuv_listener_count; i++) {
        kuv_listener *l = &kuv_listeners[i];
        if (!l->paused || !l->open) {
            continue;
        }
        if (kuv_max_handshakes > 0 && kuv_handshakes >= kuv_max_handshakes) {
            return;
        }
        l->paused = 0;
        kuv_accept_one(l);
    }
}

static void kuv_on_close(uv_handle_t *handle) {
    kuv_conn *c = (kuv_conn *)handle->data;
    kuv_slots[c->slot] = NULL;
    kuv_gens[c->slot]++;
    kuv_free[kuv_free_count++] = c->slot;
    __atomic_sub_fetch(&kuv_open, 1, __ATOMIC_RELAXED);
    if (c->handshaking) {
        kuv_handshakes--;
    }
    kiln_tls_conn_free(c->tls);
    free(c->in);
    free(c->out);
    free(c->tls_pending);
    free(c->body);
    int resume = c->handshaking;
    free(c);
    if (resume && kuv_listening && !kuv_draining) {
        kuv_resume_listeners();
    }
}

static void kuv_close(kuv_conn *c) {
    if (c->state == KUV_CONN_CLOSING) {
        return;
    }
    c->state = kuv_conn_next(c->state, KUV_CONN_CLOSE);
    c->reading = 0;
    uv_close((uv_handle_t *)&c->h, kuv_on_close);
}

static void kuv_on_shutdown(uv_shutdown_t *req, int status) {
    kuv_conn *c = (kuv_conn *)req->handle->data;
    if (status < 0) {
        kuv_close(c);
    }
}

static int kuv_raw_owned(kuv_conn *c, char *data, size_t len);

static int kuv_tls_push(kuv_conn *c) {
    size_t pending = kiln_tls_pending(c->tls);
    while (pending > 0) {
        char *copy = malloc(pending);
        if (!copy) {
            return -1;
        }
        size_t n = kiln_tls_take(c->tls, copy, pending);
        if (n == 0) {
            free(copy);
            return 0;
        }
        if (kuv_raw_owned(c, copy, n) < 0) {
            return -1;
        }
        pending = kiln_tls_pending(c->tls);
    }
    return 0;
}

static void kuv_end(kuv_conn *c) {
    if (c->state == KUV_CONN_CLOSING || c->state == KUV_CONN_LINGERING) {
        return;
    }
    if (kuv_linger_ms == 0 || c->read_eof || c->handshaking || !kuv_listening) {
        kuv_close(c);
        return;
    }
    if (c->tls) {
        kiln_tls_close_notify(c->tls);
        if (kuv_tls_push(c) < 0) {
            kuv_close(c);
            return;
        }
    }
    c->state = kuv_conn_next(c->state, KUV_CONN_LINGER);
    c->linger_since = uv_now(kuv_loop);
    c->in_len = 0;
    if (uv_shutdown(&c->shut, kuv_stream(c), kuv_on_shutdown) != 0) {
        kuv_close(c);
        return;
    }
    kuv_sync_read(c);
}

static void kuv_discard_setup_handles(int close_timer, int close_async) {
    if (close_timer) {
        uv_close((uv_handle_t *)&kuv_timer, NULL);
    }
    if (close_async) {
        uv_close((uv_handle_t *)&kuv_wakeup, NULL);
    }
    for (long i = 0; i < kuv_listener_count; i++) {
        if (kuv_listeners[i].open) {
            uv_close((uv_handle_t *)&kuv_listeners[i].h, NULL);
            kuv_listeners[i].open = 0;
        }
    }
    kuv_listener_count = 0;
    uv_run(kuv_loop, UV_RUN_NOWAIT);
}

static void kuv_queue_flush(kuv_conn *c) {
    if (c->queued_flush) {
        return;
    }
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

#define KUV_SPARE_MAX 64
#define KUV_IN_FIRST  32768
#define KUV_OUT_FIRST 4096

static char *kuv_spare_in[KUV_SPARE_MAX];
static int kuv_spare_in_count;
static char *kuv_spare_out[KUV_SPARE_MAX];
static int kuv_spare_out_count;

static void kuv_spare_put(char *buf, size_t cap) {
    if (!buf) {
        return;
    }
    if (cap == KUV_IN_FIRST && kuv_spare_in_count < KUV_SPARE_MAX) {
        kuv_spare_in[kuv_spare_in_count++] = buf;
        return;
    }
    if (cap == KUV_OUT_FIRST && kuv_spare_out_count < KUV_SPARE_MAX) {
        kuv_spare_out[kuv_spare_out_count++] = buf;
        return;
    }
    free(buf);
}

static void kuv_release_idle(kuv_conn *c) {
    if (c->state == KUV_CONN_CLOSING || c->tls || c->parse_state == KUV_PARSE_TUNNEL ||
        c->body_mode != KUV_BODY_NONE || c->parse_state == KUV_PARSE_UPGRADE || c->in_len != 0 ||
        c->out_len != 0 || c->writes != 0) {
        return;
    }
    kuv_spare_put(c->in, c->in_cap);
    c->in = NULL;
    c->in_cap = 0;
    kuv_spare_put(c->out, c->out_cap);
    c->out = NULL;
    c->out_cap = 0;
}

static int kuv_reserve(char **buf, size_t len, size_t *cap, size_t n) {
    if (n > UINT_MAX || len > UINT_MAX - n) {
        return -1;
    }
    size_t required = len + n;
    if (required <= *cap) {
        return 0;
    }
    if (*cap == 0 && required <= KUV_OUT_FIRST && kuv_spare_out_count > 0) {
        *buf = kuv_spare_out[--kuv_spare_out_count];
        *cap = KUV_OUT_FIRST;
        return 0;
    }
    size_t want = *cap ? *cap : KUV_OUT_FIRST;
    while (want < required) {
        if (want > UINT_MAX / 2U) {
            want = required;
            break;
        }
        want *= 2;
    }
    char *grown = realloc(*buf, want);
    if (!grown) {
        return -1;
    }
    *buf = grown;
    *cap = want;
    return 0;
}

static int kuv_append(char **buf, size_t *len, size_t *cap, const char *data, size_t n) {
    if (kuv_reserve(buf, *len, cap, n) < 0) {
        return -1;
    }
    memcpy(*buf + *len, data, n);
    *len += n;
    return 0;
}

static int kuv_append_pair(
    kuv_conn *c, const char *head, size_t head_len, const char *body, size_t body_len) {
    if (head_len > UINT_MAX || body_len > UINT_MAX - head_len) {
        return -1;
    }
    size_t pair_len = head_len + body_len;
    if (kuv_reserve(&c->out, c->out_len, &c->out_cap, pair_len) < 0) {
        return -1;
    }
    memcpy(c->out + c->out_len, head, head_len);
    c->out_len += head_len;
    if (body_len > 0) {
        memcpy(c->out + c->out_len, body, body_len);
        c->out_len += body_len;
    }
    return 0;
}

static void kuv_reply_and_close(kuv_conn *c, const char *msg) {
    if (c->handshaking) {
        kuv_close(c);
        return;
    }
    if (kuv_append(&c->out, &c->out_len, &c->out_cap, msg, strlen(msg)) < 0) {
        kuv_close(c);
        return;
    }
    c->state = kuv_conn_next(c->state, KUV_CONN_FINISH);
    kuv_stop_parsing(c);
    kuv_sync_read(c);
    kuv_queue_flush(c);
}

static void kuv_error(kuv_conn *c, const char *msg) {
    if (c->pending > 0 || c->awaiting > 0) {
        c->deferred_error = msg;
        kuv_stop_parsing(c);
        kuv_sync_read(c);
        return;
    }
    kuv_reply_and_close(c, msg);
}

static void kuv_maybe_continue(kuv_conn *c) {
    if (c->expect_state != KUV_EXPECT_BUFFERED || c->pending > 0 || c->awaiting > 0 ||
        c->state == KUV_CONN_CLOSING) {
        return;
    }
    if (kuv_append(&c->out, &c->out_len, &c->out_cap, KUV_CONTINUE, sizeof(KUV_CONTINUE) - 1) < 0) {
        kuv_close(c);
        return;
    }
    c->expect_state = KUV_EXPECT_SENT;
    kuv_queue_flush(c);
}

static size_t kuv_align8(size_t n) {
    return (n + 7U) & ~(size_t)7U;
}

static kuv_req *kuv_req_make(
    const char *bytes, const int64_t *scan, const kiln_uv_parse_result *parsed, const kuv_conn *c) {
    size_t total = parsed->total_len;
    size_t nscan = (size_t)(5 + (5 * parsed->nheaders));
    size_t scan_off = kuv_align8(sizeof(kuv_req));
    size_t data_off = scan_off + (nscan * sizeof(int64_t));
    if (total > SIZE_MAX - data_off) {
        return NULL;
    }
    unsigned char *block = malloc(data_off + total);
    if (!block) {
        return NULL;
    }
    kuv_req *r = (kuv_req *)block;
    r->slot = c->slot;
    r->gen = c->gen;
    r->len = (long)total;
    r->nheaders = parsed->nheaders;
    r->body_start = (long)parsed->head_len + 4;
    r->body_len = parsed->streamed ? 0 : parsed->body_len;
    r->declared = parsed->body_len;
    r->flags = (parsed->streamed ? KUV_FLAG_STREAMED : 0) |
               (parsed->chunked ? KUV_FLAG_CHUNKED : 0) | (parsed->upgrade ? KUV_FLAG_UPGRADE : 0) |
               (c->tls ? KUV_FLAG_TLS : 0);
    r->listener = c->listener;
    r->next = NULL;
    r->scan = (int64_t *)(block + scan_off);
    r->data = (char *)(block + data_off);
    memcpy(r->scan, scan, nscan * sizeof(int64_t));
    memcpy(r->data, bytes, total);
    return r;
}

static void kuv_consume(kuv_conn *c, size_t used) {
    if (used == 0) {
        return;
    }
    memmove(c->in, c->in + used, c->in_len - used);
    c->in_len -= used;
}

static void kuv_body_release(kuv_conn *c) {
    c->body_mode = KUV_BODY_NONE;
    c->body_state = KUV_BODY_IDLE;
    c->body_discard = 0;
    c->expect_state = KUV_EXPECT_NONE;
    c->body_error = 0;
    c->body_len = 0;
    if (c->body_cap > KUV_BODY_HIGH) {
        free(c->body);
        c->body = NULL;
        c->body_cap = 0;
    }
}

static void kuv_body_chunked(kuv_conn *c, size_t *used) {
    for (;;) {
        if (kuv_reserve(&c->body, c->body_len, &c->body_cap, 16384) < 0) {
            c->body_error = 400;
            c->body_state = KUV_BODY_FAILED;
            return;
        }
        size_t consumed = 0;
        size_t produced = 0;
        int rc = kiln_uv_chunk_decode(&c->chunk, c->in + *used, c->in_len - *used,
            c->body + c->body_len, c->body_cap - c->body_len, &consumed, &produced);
        *used += consumed;
        if (!c->body_discard) {
            c->body_len += produced;
        }
        if (rc < KILN_UV_CHUNK_MORE) {
            c->body_error = 400;
            c->body_state = KUV_BODY_FAILED;
            if (rc == KILN_UV_CHUNK_TOO_BIG) {
                c->body_error = 431;
            }
            if (rc == KILN_UV_CHUNK_HUGE) {
                c->body_error = 413;
            }
            return;
        }
        if (rc == KILN_UV_CHUNK_END) {
            kuv_body_complete(c);
            return;
        }
        if (consumed == 0 && produced == 0) {
            return;
        }
    }
}

static size_t kuv_body_copy(kuv_conn *c) {
    size_t n = c->in_len;
    if (c->body_mode == KUV_BODY_LENGTH && (size_t)c->body_left < n) {
        n = (size_t)c->body_left;
    }
    if (!c->body_discard && kuv_append(&c->body, &c->body_len, &c->body_cap, c->in, n) < 0) {
        c->body_error = 400;
        c->body_state = KUV_BODY_FAILED;
        return 0;
    }
    if (c->body_mode == KUV_BODY_LENGTH) {
        c->body_left -= (long)n;
    }
    return n;
}

static void kuv_body_feed(kuv_conn *c) {
    if (c->body_state == KUV_BODY_DONE || c->body_error || c->in_len == 0) {
        return;
    }
    size_t used = 0;
    if (c->body_mode == KUV_BODY_CHUNKED) {
        kuv_body_chunked(c, &used);
    } else {
        used = kuv_body_copy(c);
    }
    kuv_consume(c, used);
}

static void kuv_body_pump(kuv_conn *c) {
    if (c->body_mode == KUV_BODY_NONE) {
        return;
    }
    kuv_body_feed(c);
    if (c->body_mode == KUV_BODY_LENGTH && c->body_left == 0) {
        kuv_body_complete(c);
    }
    if (c->body_error) {
        kuv_stop_parsing(c);
        c->in_len = 0;
    } else if (c->body_state == KUV_BODY_DONE && c->parse_state >= KUV_PARSE_STOPPED) {
        c->in_len = 0;
    }
    if (c->body_discard && c->body_state == KUV_BODY_DONE && !c->body_error) {
        kuv_body_release(c);
        c->resume_parse = 1;
    }
    if (c->body_mode != KUV_BODY_NONE && !c->body_discard && c->body_len >= KUV_BODY_HIGH) {
        kuv_body_pause(c);
    }
    kuv_sync_read(c);
}

static const char *kuv_error_reply(int status) {
    switch (status) {
    case 501:
        return KUV_501;
    case 413:
        return KUV_413;
    case 417:
        return KUV_417;
    case 431:
        return KUV_431;
    default:
        return KUV_400;
    }
}

static int kuv_enqueue(
    kuv_conn *c, const char *start, const int64_t *scan, const kiln_uv_parse_result *parsed) {
    kuv_req *r = kuv_req_make(start, scan, parsed, c);
    if (!r) {
        kuv_close(c);
        return -1;
    }
    if (kuv_tail) {
        kuv_tail->next = r;
    } else {
        kuv_head = r;
    }
    kuv_tail = r;
    kuv_ready++;
    c->pending++;
    c->served++;
    c->expect_state = KUV_EXPECT_NONE;

    return 0;
}

static void kuv_start_body(kuv_conn *c, const kiln_uv_parse_result *parsed, int close) {
    c->body_state = KUV_BODY_READING;
    c->body_mode = parsed->chunked ? KUV_BODY_CHUNKED : KUV_BODY_LENGTH;
    c->body_left = parsed->chunked ? 0 : parsed->body_len;
    c->body_error = 0;
    c->body_discard = 0;
    kuv_body_resume(c);
    c->body_len = 0;
    c->expect_state = parsed->expect_continue ? KUV_EXPECT_STREAMED : KUV_EXPECT_NONE;
    kiln_uv_chunk_init(&c->chunk);
    if (close) {
        kuv_stop_parsing(c);
    }
}

static void kuv_track_head(kuv_conn *c) {
    if (c->in_len > 0 && c->body_mode == KUV_BODY_NONE) {
        if (c->head_state == KUV_HEAD_IDLE) {
            c->head_state = KUV_HEAD_READING;
            c->head_since = uv_now(kuv_loop);
        }
    } else {
        c->head_state = KUV_HEAD_IDLE;
    }
}

static void kuv_parse(kuv_conn *c) {
    size_t pos = 0;
    int partial_head = 0;
    while (c->state == KUV_CONN_OPEN && c->parse_state == KUV_PARSE_OPEN &&
           c->body_mode == KUV_BODY_NONE && pos < c->in_len) {
        if (c->pending + c->awaiting >= KUV_PIPELINE_MAX) {
            c->read_paused = 1;
            break;
        }
        if (kuv_out_bytes(c) >= KUV_OUT_HIGH) {
            c->out_paused = 1;
            break;
        }
        const char *start = c->in + pos;
        size_t avail = c->in_len - pos;
        int64_t scan[KILN_UV_SCAN_CAP];
        kiln_uv_parse_result parsed;
        size_t scan_from = pos == 0 ? c->head_scanned : 0;
        int state = kiln_uv_parse_request_from(
            start, avail, scan_from, kuv_buffer_body, scan, KILN_UV_SCAN_CAP, &parsed);
        if (state < 0) {
            c->head_scanned = 0;
            kuv_close(c);
            return;
        }
        if (state == KILN_UV_PARSE_ERROR) {
            kuv_error(c, kuv_error_reply(parsed.error_status));
            break;
        }
        if (state == KILN_UV_PARSE_INCOMPLETE) {
            c->head_state = parsed.head_len > 0 ? KUV_HEAD_BODY : KUV_HEAD_READING;
            partial_head = parsed.head_len == 0;
            if (parsed.expect_continue) {
                if (c->expect_state == KUV_EXPECT_NONE) {
                    c->expect_state = KUV_EXPECT_BUFFERED;
                }
                kuv_maybe_continue(c);
            }
            break;
        }
        partial_head = 0;
        if (kuv_enqueue(c, start, scan, &parsed) < 0) {
            c->head_scanned = 0;
            return;
        }
        pos += parsed.total_len;
        int close = parsed.has_close || (parsed.minor == 0 && !parsed.has_keep);
        if (parsed.streamed) {
            c->head_scanned = 0;
            kuv_consume(c, pos);
            kuv_start_body(c, &parsed, close);
            c->head_state = KUV_HEAD_IDLE;
            kuv_body_pump(c);
            return;
        }
        if (close) {
            kuv_stop_parsing(c);
        } else if (parsed.upgrade) {
            c->parse_state = KUV_PARSE_UPGRADE;
        }
        if (pos < c->in_len) {
            c->head_state = KUV_HEAD_READING;
            c->head_since = uv_now(kuv_loop);
        } else {
            c->head_state = KUV_HEAD_IDLE;
        }
    }
    if (c->parse_state >= KUV_PARSE_STOPPED && c->body_mode == KUV_BODY_NONE) {
        c->in_len = 0;
        c->head_state = KUV_HEAD_IDLE;
        c->head_scanned = 0;
    } else {
        kuv_consume(c, pos);
        c->head_scanned = partial_head ? c->in_len : 0;
    }
    kuv_sync_read(c);
}

static void kuv_out_resume(kuv_conn *c) {
    if (!c->out_paused || c->state == KUV_CONN_CLOSING || kuv_out_bytes(c) >= KUV_OUT_LOW) {
        return;
    }
    c->out_paused = 0;
    if (c->parse_state == KUV_PARSE_OPEN && c->body_mode == KUV_BODY_NONE && !kuv_draining) {
        kuv_track_head(c);
        kuv_parse(c);
    } else {
        kuv_sync_read(c);
    }
}

static void kuv_ingest(kuv_conn *c) {
    if (c->body_mode != KUV_BODY_NONE) {
        kuv_body_pump(c);
        if (c->body_mode != KUV_BODY_NONE || !c->resume_parse ||
            c->parse_state >= KUV_PARSE_STOPPED || c->state == KUV_CONN_CLOSING || kuv_draining) {
            return;
        }
        c->resume_parse = 0;
    }
    kuv_track_head(c);
    if (c->parse_state != KUV_PARSE_UPGRADE) {
        kuv_parse(c);
    }
}

static void kuv_alloc(uv_handle_t *handle, size_t suggested, uv_buf_t *buf) {
    kuv_conn *c = (kuv_conn *)handle->data;
    (void)suggested;
    if (c->tls || c->state == KUV_CONN_LINGERING) {
        buf->base = kuv_tls_scratch;
        buf->len = sizeof(kuv_tls_scratch);
        return;
    }
    if (c->in_cap == 0 && kuv_spare_in_count > 0) {
        c->in = kuv_spare_in[--kuv_spare_in_count];
        c->in_cap = KUV_IN_FIRST;
    }
    if (c->in_cap - c->in_len < 16384) {
        size_t want = c->in_cap ? c->in_cap * 2 : KUV_IN_FIRST;
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

static void kuv_handshake_done(kuv_conn *c) {
    c->handshaking = 0;
    kuv_handshakes--;
    kuv_resume_listeners();
}

static int kuv_tls_in(kuv_conn *c, const char *data, size_t len) {
    if (kiln_tls_feed(c->tls, data, len) != KILN_TLS_DONE) {
        return KILN_TLS_FAIL;
    }
    if (c->handshaking) {
        int hs = kiln_tls_handshake(c->tls);
        if (kuv_tls_push(c) < 0 || hs == KILN_TLS_FAIL || hs == KILN_TLS_CLOSED) {
            return KILN_TLS_FAIL;
        }
        if (hs == KILN_TLS_WANT) {
            return KILN_TLS_WANT;
        }
        kuv_handshake_done(c);
    }
    if (c->tls_pending && c->tls_wait == KILN_TLS_WANT_READ) {
        c->tls_wait = 0;
        kuv_flush_tls(c);
        if (c->state == KUV_CONN_CLOSING) {
            return KILN_TLS_FAIL;
        }
        kuv_sync_read(c);
    }
    if (c->tls_pending && c->tls_wait == KILN_TLS_WANT_WRITE) {
        return KILN_TLS_WANT;
    }
    for (;;) {
        if (kuv_reserve(&c->in, c->in_len, &c->in_cap, KUV_TLS_READ) < 0) {
            return KILN_TLS_FAIL;
        }
        long n = kiln_tls_read(c->tls, c->in + c->in_len, c->in_cap - c->in_len);
        if (n > 0) {
            c->in_len += (size_t)n;
            continue;
        }
        if (kuv_tls_push(c) < 0) {
            return KILN_TLS_FAIL;
        }
        return (int)n;
    }
}

static int kuv_body_eof(kuv_conn *c) {
    if (c->body_state != KUV_BODY_DONE && !c->body_error) {
        kuv_body_pump(c);
        if (c->body_mode == KUV_BODY_TUNNEL) {
            kuv_body_complete(c);
        } else if (c->body_state != KUV_BODY_DONE) {
            c->body_error = KUV_GONE;
            c->body_state = KUV_BODY_FAILED;
        }
    }
    return c->parse_state == KUV_PARSE_TUNNEL || c->pending > 0 || c->awaiting > 0;
}

static void kuv_finish_eof(kuv_conn *c) {
    if (c->deferred_error) {
        const char *error = c->deferred_error;
        c->deferred_error = NULL;
        kuv_reply_and_close(c, error);
        return;
    }
    c->state = kuv_conn_next(c->state, KUV_CONN_FINISH);
    if (c->out_len > 0) {
        kuv_queue_flush(c);
    } else if (c->writes == 0) {
        kuv_close(c);
    }
}

static void kuv_on_read_end(kuv_conn *c) {
    c->read_eof = 1;
    kuv_sync_read(c);
    if (c->state == KUV_CONN_LINGERING) {
        kuv_close(c);
        return;
    }
    if (c->body_mode != KUV_BODY_NONE && kuv_body_eof(c)) {
        return;
    }
    if (c->parse_state == KUV_PARSE_OPEN && c->state != KUV_CONN_CLOSING) {
        kuv_parse(c);
    }
    if (c->state == KUV_CONN_CLOSING) {
        return;
    }
    if (c->read_paused && c->in_len > 0 && c->parse_state < KUV_PARSE_STOPPED) {
        return;
    }
    kuv_stop_parsing(c);
    c->read_paused = 0;
    c->in_len = 0;
    if (c->pending == 0 && c->awaiting == 0) {
        kuv_finish_eof(c);
    }
}

static void kuv_on_read(uv_stream_t *stream, ssize_t nread, const uv_buf_t *buf) {
    kuv_conn *c = (kuv_conn *)stream->data;
    if (nread < 0) {
        if (nread == UV_EOF) {
            kuv_on_read_end(c);
        } else {
            kuv_close(c);
        }
        return;
    }
    if (nread == 0) {
        return;
    }
    c->last_active = uv_now(kuv_loop);
    if (c->state == KUV_CONN_LINGERING) {
        return;
    }
    if (c->tls) {
        int rc = kuv_tls_in(c, buf->base, (size_t)nread);
        if (rc == KILN_TLS_FAIL) {
            kuv_close(c);
            return;
        }
        if (rc == KILN_TLS_CLOSED) {
            kuv_ingest(c);
            if (c->state != KUV_CONN_CLOSING) {
                kuv_on_read_end(c);
            }
            return;
        }
        if (c->handshaking || c->in_len == 0) {
            return;
        }
    } else {
        c->in_len += (size_t)nread;
    }
    kuv_ingest(c);
}

static void kuv_conn_init(kuv_conn *c, const kuv_listener *l) {
    if (l->kind == KUV_UNIX) {
        uv_pipe_init(kuv_loop, &c->h.pipe, 0);
    } else {
        uv_tcp_init(kuv_loop, &c->h.tcp);
    }
}

static void kuv_accept_one(kuv_listener *l) {
    kuv_conn *c = calloc(1, sizeof(kuv_conn));
    if (!c) {
        return;
    }
    kuv_conn_init(c, l);
    if (uv_accept((uv_stream_t *)&l->h, kuv_stream(c)) != 0 || kuv_free_count == 0) {
        uv_close((uv_handle_t *)&c->h, (uv_close_cb)free);
        return;
    }
    c->slot = kuv_free[--kuv_free_count];
    c->gen = kuv_gens[c->slot];
    c->h.tcp.data = c;
    c->listener = (int)(l - kuv_listeners);
    c->last_active = uv_now(kuv_loop);
    c->head_state = KUV_HEAD_READING;
    c->head_since = c->last_active;
    kuv_slots[c->slot] = c;
    long open = __atomic_add_fetch(&kuv_open, 1, __ATOMIC_RELAXED);
    if (l->kind == KUV_TCP && kuv_nodelay) {
        uv_tcp_nodelay(&c->h.tcp, 1);
    }
#ifdef SO_NOSIGPIPE
    uv_os_fd_t fd;
    if (uv_fileno((uv_handle_t *)&c->h, &fd) == 0) {
        kiln_sock_nosigpipe((long)fd);
    }
#endif
    if (l->tls >= 0) {
        c->tls = kiln_tls_conn_new(l->tls);
        if (!c->tls || open > kuv_max_conns) {
            kuv_close(c);
            return;
        }
        c->handshaking = 1;
        kuv_handshakes++;
    } else if (open > kuv_max_conns) {
        kuv_reply_and_close(c, KUV_503);
        return;
    }
    kuv_sync_read(c);
}

static void kuv_on_connection(uv_stream_t *server, int status) {
    if (status < 0) {
        return;
    }
    kuv_listener *l = (kuv_listener *)server->data;
    if (l->tls >= 0 && kuv_max_handshakes > 0 && kuv_handshakes >= kuv_max_handshakes) {
        l->paused = 1;
        return;
    }
    kuv_accept_one(l);
}

static uint64_t kuv_tick_ms(void) {
    uint64_t tick = 1000;
    uint64_t limits[] = {kuv_header_ms, kuv_keepalive_ms, kuv_read_ms, kuv_write_ms, kuv_linger_ms};
    for (size_t i = 0; i < sizeof(limits) / sizeof(limits[0]); i++) {
        if (limits[i] > 0 && limits[i] < tick) {
            tick = limits[i];
        }
    }
    return tick < 1 ? 1 : tick;
}

static void kuv_expire_waiting(kuv_conn *c, uint64_t now) {
    if (c->handshaking) {
        if (now - c->head_since > kuv_header_ms) {
            kuv_close(c);
        }
        return;
    }
    if (c->head_state != KUV_HEAD_IDLE) {
        uint64_t limit =
            c->head_state == KUV_HEAD_BODY ? kuv_header_ms + kuv_read_ms : kuv_header_ms;
        if (now - c->head_since <= limit) {
            return;
        }
        if (c->in_len == 0) {
            kuv_close(c);
        } else {
            kuv_reply_and_close(c, KUV_408);
        }
        return;
    }
    uint64_t idle = c->served == 0 ? kuv_header_ms : kuv_keepalive_ms;
    if (c->in_len == 0 && now - c->last_active > idle) {
        kuv_end(c);
    }
}

static void kuv_expire(kuv_conn *c, uint64_t now) {
    if (c->state == KUV_CONN_LINGERING) {
        if (now - c->linger_since > kuv_linger_ms) {
            kuv_close(c);
        }
    } else if (c->tls_pending && c->tls_wait) {
        if (kuv_write_ms > 0 && now - c->tls_write_since > kuv_write_ms) {
            kuv_close(c);
        }
    } else if (c->writes > 0) {
        if (kuv_write_ms > 0 && now - c->write_started > kuv_write_ms) {
            kuv_close(c);
        }
    } else if (c->body_discard) {
        if (now - c->last_active > kuv_read_ms) {
            kuv_close(c);
        }
    } else if (c->parse_state != KUV_PARSE_TUNNEL && c->body_mode == KUV_BODY_NONE &&
               c->pending == 0 && c->awaiting == 0 && c->state != KUV_CONN_FLUSHING) {
        kuv_expire_waiting(c, now);
    }
}

static void kuv_on_timer(uv_timer_t *timer) {
    (void)timer;
    uint64_t now = uv_now(kuv_loop);
    for (long i = 0; i < KUV_MAX_SLOTS; i++) {
        kuv_conn *c = kuv_slots[i];
        if (c && c->state != KUV_CONN_CLOSING) {
            kuv_expire(c, now);
        }
    }
}

long kiln_uv_configure(const int64_t *cfg, long n) {
    if (kuv_listening || n < KUV_CONFIG_SIZE) {
        return UV_EALREADY;
    }
    if (!kuv_configured || kiln_uv_open() == 0) {
        kuv_loop = uv_default_loop();
        kuv_free_count = 0;
        for (long i = KUV_MAX_SLOTS - 1; i >= 0; i--) {
            kuv_free[kuv_free_count++] = (uint32_t)i;
        }
        kuv_configured = 1;
    }
    kuv_max_conns = (long)cfg[0];
    kuv_buffer_body = (long)cfg[1];
    kuv_header_ms = (uint64_t)(cfg[2] < 1 ? 1 : cfg[2]);
    kuv_keepalive_ms = (uint64_t)(cfg[3] < 0 ? 0 : cfg[3]);
    kuv_read_ms = (uint64_t)(cfg[4] < 1 ? 1 : cfg[4]);
    kuv_write_ms = (uint64_t)(cfg[5] < 1 ? 1 : cfg[5]);
    kuv_linger_ms = (uint64_t)(cfg[6] < 0 ? 0 : cfg[6]);
    kuv_nodelay = cfg[7] != 0;
    kuv_max_handshakes = (long)cfg[8];
    kuv_backlog = cfg[9] < 1 ? 1024 : (long)cfg[9];
    kuv_aborted = 0;
    kuv_handshakes = 0;
    return 0;
}

long kiln_uv_adopt(long fd, long tls) {
    if (!kuv_configured || kuv_listening) {
        return UV_EALREADY;
    }
    if (kuv_listener_count >= KUV_MAX_LISTENERS) {
        return UV_ENOBUFS;
    }
    long kind = kiln_sock_adopt(fd);
    if (kind < 0) {
        return UV_EINVAL;
    }
    kuv_listener *l = &kuv_listeners[kuv_listener_count];
    memset(l, 0, sizeof *l);
    l->kind = (int)kind;
    l->tls = (int)tls;
    int rc =
        kind == KUV_UNIX ? uv_pipe_init(kuv_loop, &l->h.pipe, 0) : uv_tcp_init(kuv_loop, &l->h.tcp);
    if (rc != 0) {
        return rc;
    }
    rc = kind == KUV_UNIX ? uv_pipe_open(&l->h.pipe, (uv_file)fd)
                          : uv_tcp_open(&l->h.tcp, (uv_os_sock_t)fd);
    l->h.tcp.data = l;
    l->open = 1;
    kuv_listener_count++;
    if (rc != 0) {
        kuv_discard_setup_handles(0, 0);
        return rc;
    }
    return kuv_listener_count - 1;
}

long kiln_uv_start(void) {
    if (!kuv_configured || kuv_listening || kuv_listener_count == 0) {
        return UV_EINVAL;
    }
    for (long i = 0; i < kuv_listener_count; i++) {
        int rc = uv_listen((uv_stream_t *)&kuv_listeners[i].h, (int)kuv_backlog, kuv_on_connection);
        if (rc != 0) {
            kuv_discard_setup_handles(0, 0);
            return rc;
        }
    }
    int rc = uv_async_init(kuv_loop, &kuv_wakeup, NULL);
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

long kiln_uv_abandon(void) {
    if (kuv_listening || !kuv_configured) {
        return 0;
    }
    kuv_discard_setup_handles(0, 0);
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

long kiln_uv_port(long index) {
    struct sockaddr_storage addr;
    int len = sizeof(addr);
    if (index < 0 || index >= kuv_listener_count || kuv_listeners[index].kind != KUV_TCP) {
        return 0;
    }
    if (uv_tcp_getsockname(&kuv_listeners[index].h.tcp, (struct sockaddr *)&addr, &len) != 0) {
        return -1;
    }
    if (addr.ss_family == AF_INET6) {
        return ntohs(((struct sockaddr_in6 *)&addr)->sin6_port);
    }
    return ntohs(((struct sockaddr_in *)&addr)->sin_port);
}

long kiln_uv_fd(void) {
    return uv_backend_fd(kuv_loop);
}

long kiln_uv_poll(void) {
    uv_run(kuv_loop, UV_RUN_NOWAIT);
    return kuv_ready;
}

long kiln_uv_settle(void) {
    if (!kuv_loop || uv_backend_timeout(kuv_loop) != 0) {
        return 0;
    }
    uv_run(kuv_loop, UV_RUN_NOWAIT);
    return 1;
}

long kiln_uv_timeout(void) {
    return kuv_loop ? uv_backend_timeout(kuv_loop) : -1;
}

static int kuv_out_blocked(const kuv_conn *c) {
    return c->out_paused || kuv_out_bytes(c) >= KUV_OUT_HIGH;
}

static kuv_req *kuv_take_ready(void) {
    kuv_req *prev = NULL;
    kuv_req *r = kuv_head;
    while (r) {
        kuv_conn *c = kuv_slots[r->slot];
        int live = c && c->gen == r->gen && c->state != KUV_CONN_CLOSING;
        if (!live || !kuv_out_blocked(c)) {
            if (prev) {
                prev->next = r->next;
            } else {
                kuv_head = r->next;
            }
            if (kuv_tail == r) {
                kuv_tail = prev;
            }
            r->next = NULL;
            kuv_ready--;
            return r;
        }
        uint32_t slot = r->slot;
        uint32_t gen = r->gen;
        while (r && r->slot == slot && r->gen == gen) {
            prev = r;
            r = r->next;
        }
    }
    return NULL;
}

const char *kiln_uv_next(int64_t *scan, long cap, int64_t *meta) {
    if (kuv_current) {
        free(kuv_current);
        kuv_current = NULL;
    }
    while (kuv_head && cap >= KILN_UV_SCAN_CAP) {
        kuv_req *r = kuv_take_ready();
        if (!r) {
            break;
        }
        kuv_conn *c = kuv_slots[r->slot];
        int live = c && c->gen == r->gen;
        if (live) {
            c->pending--;
        }
        if (!live || c->state >= KUV_CONN_FLUSHING || c->refused) {
            if (kuv_draining && !(live && c->refused)) {
                kuv_aborted++;
            }
            free(r);
            continue;
        }
        c->awaiting++;
        kuv_current = r;
        memcpy(scan, r->scan, sizeof(int64_t) * (size_t)(5 + (5 * r->nheaders)));
        meta[0] = r->nheaders;
        meta[1] = r->body_start;
        meta[2] = r->body_len;
        meta[3] = r->slot;
        meta[4] = r->gen;
        meta[5] = r->flags;
        meta[6] = r->declared;
        meta[7] = r->listener;
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
    if (c->writes == 0) {
        c->write_started = 0;
    }
    if (status < 0) {
        kuv_close(c);
        return;
    }
    if (c->tls_pending && c->tls_wait == KILN_TLS_WANT_WRITE && c->writes == 0) {
        c->tls_wait = 0;
        kuv_flush_tls(c);
        if (c->state != KUV_CONN_CLOSING && !c->tls_pending) {
            int read_rc = kuv_tls_in(c, NULL, 0);
            if (read_rc == KILN_TLS_FAIL) {
                kuv_close(c);
            } else if (read_rc == KILN_TLS_CLOSED) {
                kuv_ingest(c);
                if (c->state != KUV_CONN_CLOSING) {
                    kuv_on_read_end(c);
                }
            } else if (c->in_len > 0) {
                kuv_ingest(c);
            }
        }
    }
    kuv_out_resume(c);
    if (c->state == KUV_CONN_FLUSHING && c->writes == 0 && c->out_len == 0 && !c->tls_pending) {
        kuv_end(c);
    }
    kuv_release_idle(c);
}

static int kuv_queue_write(kuv_conn *c, char *owned, char *from, size_t len) {
    if (len > UINT_MAX) {
        free(owned);
        return -1;
    }
    kuv_write *w = malloc(sizeof(*w));
    if (!w) {
        free(owned);
        return -1;
    }
    w->conn = c;
    w->data = owned;
    w->len = len;
    uv_buf_t wb = uv_buf_init(from, (unsigned int)len);
    if (c->writes++ == 0) {
        c->write_started = uv_now(kuv_loop);
    }
    if (uv_write(&w->req, kuv_stream(c), &wb, 1, kuv_after_write) != 0) {
        c->writes--;
        if (c->writes == 0) {
            c->write_started = 0;
        }
        free(owned);
        free(w);
        return -1;
    }
    c->sending += len;
    return 0;
}

static int kuv_raw_owned(kuv_conn *c, char *data, size_t len) {
    if (len > UINT_MAX) {
        free(data);
        return -1;
    }
    size_t done = 0;
    if (c->writes == 0) {
        uv_buf_t b = uv_buf_init(data, (unsigned int)len);
        int wrote = uv_try_write(kuv_stream(c), &b, 1);
        if (wrote < 0 && wrote != UV_EAGAIN) {
            free(data);
            return -1;
        }
        done = wrote > 0 ? (size_t)wrote : 0;
    }
    if (done == len) {
        free(data);
        return 0;
    }
    return kuv_queue_write(c, data, data + done, len - done);
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
    if (!copy) {
        return NULL;
    }
    size_t filled = 0;
    if (done < head_len) {
        size_t n = head_len - done;
        memcpy(copy, head + done, n);
        filled = n;
        done = 0;
    } else {
        done -= head_len;
    }
    if (done < body_len) {
        memcpy(copy + filled, body + done, body_len - done);
    }
    return copy;
}

static int kuv_writev_now(
    kuv_conn *c, const char *head, size_t head_len, const char *body, size_t body_len) {
    if (head_len > UINT_MAX || body_len > UINT_MAX - head_len) {
        return -1;
    }
    uv_buf_t bufs[2];
    unsigned int nbufs = 0;
    if (head_len > 0) {
        bufs[nbufs++] = uv_buf_init((char *)head, (unsigned int)head_len);
    }
    if (body_len > 0) {
        bufs[nbufs++] = uv_buf_init((char *)body, (unsigned int)body_len);
    }
    if (nbufs == 0) {
        return 0;
    }
    int done = uv_try_write(kuv_stream(c), bufs, nbufs);
    if (done < 0 && done != UV_EAGAIN) {
        return -1;
    }
    if (done <= 0) {
        return 1;
    }
    size_t rest = 0;
    char *copy = kuv_unsent(head, head_len, body, body_len, (size_t)done, &rest);
    if (rest == 0) {
        return 0;
    }
    if (!copy || kuv_queue_write(c, copy, copy, rest) < 0) {
        return -1;
    }
    return 0;
}

static int kuv_try_direct(
    kuv_conn *c, const char *head, size_t head_len, const char *body, size_t body_len) {
    if (c->tls || body_len < KUV_WRITEV_MIN || c->out_len != 0 || c->writes != 0) {
        return 1;
    }
    int wr = kuv_writev_now(c, head, head_len, body, body_len);
    if (wr < 0) {
        kuv_close(c);
        return -1;
    }
    return wr == 0 ? 0 : 1;
}

static void kuv_settle(kuv_conn *c) {
    if (c->out_len > 0) {
        kuv_queue_flush(c);
    } else if (c->state == KUV_CONN_FLUSHING && c->writes == 0 && !c->tls_pending) {
        kuv_end(c);
    }
}

static void kuv_send_finish(kuv_conn *c, long close_after) {
    int hit_zero = 0;
    if (c->parse_state == KUV_PARSE_UPGRADE) {
        kuv_release_upgrade(c);
        c->resume_parse = 1;
    }
    if ((c->read_paused || c->resume_parse) && c->parse_state < KUV_PARSE_STOPPED &&
        !kuv_draining && c->body_mode == KUV_BODY_NONE) {
        c->read_paused = 0;
        c->resume_parse = 0;
        kuv_track_head(c);
        kuv_parse(c);
    }
    if (c->deferred_error && c->pending == 0 && c->awaiting == 0) {
        const char *error = c->deferred_error;
        c->deferred_error = NULL;
        if (!kuv_draining) {
            kuv_reply_and_close(c, error);
        }
    }
    if (c->read_eof && c->pending == 0 && c->awaiting == 0 && c->body_mode == KUV_BODY_NONE) {
        close_after = 1;
    }
    if (!close_after && kuv_draining && c->drain_remaining > 0) {
        c->drain_remaining--;
        hit_zero = c->drain_remaining == 0;
    }
    if (close_after || hit_zero) {
        c->state = kuv_conn_next(c->state, KUV_CONN_FINISH);
        kuv_stop_parsing(c);
    }
    c->last_active = uv_now(kuv_loop);
    if (c->head_state != KUV_HEAD_IDLE) {
        c->head_since = c->last_active;
    }
    kuv_sync_read(c);
    kuv_settle(c);
    kuv_maybe_continue(c);
}

long kiln_uv_send(long slot, long gen, const char *head, long head_len, const char *body,
    long body_len, long close_after) {
    if (slot < 0 || slot >= KUV_MAX_SLOTS || head_len < 0 || body_len < 0) {
        return -1;
    }
    kuv_conn *c = kuv_slots[slot];
    if (!c || c->gen != (uint32_t)gen || c->state != KUV_CONN_OPEN) {
        return -1;
    }
    if (c->awaiting > 0) {
        c->awaiting--;
    }
    int append = kuv_try_direct(c, head, (size_t)head_len, body, (size_t)body_len);
    if (append < 0) {
        return -1;
    }
    if (append && kuv_append_pair(c, head, (size_t)head_len, body, (size_t)body_len) < 0) {
        kuv_close(c);
        return -1;
    }
    kuv_send_finish(c, close_after);
    return 0;
}

static kuv_conn *kuv_live(long slot, long gen) {
    if (slot < 0 || slot >= KUV_MAX_SLOTS) {
        return NULL;
    }
    kuv_conn *c = kuv_slots[slot];
    if (!c || c->gen != (uint32_t)gen || c->state >= KUV_CONN_FLUSHING) {
        return NULL;
    }
    return c;
}

long kiln_uv_part(long slot, long gen, const char *data, long len) {
    kuv_conn *c = kuv_live(slot, gen);
    if (!c || len < 0) {
        return -1;
    }
    if (len > 0) {
        if (kuv_append(&c->out, &c->out_len, &c->out_cap, data, (size_t)len) < 0) {
            kuv_close(c);
            return -1;
        }
        c->last_active = uv_now(kuv_loop);
        kuv_queue_flush(c);
    }
    return (long)(c->out_len + c->sending + c->tls_pending_len - c->tls_pending_off);
}

long kiln_uv_backlog(long slot, long gen) {
    const kuv_conn *c = kuv_live(slot, gen);
    return c ? (long)kuv_out_bytes(c) : -1;
}

long kiln_uv_refuse(long slot, long gen) {
    kuv_conn *c = kuv_live(slot, gen);
    if (!c) {
        return -1;
    }
    c->refused = 1;
    kuv_stop_parsing(c);
    kuv_sync_read(c);
    return 0;
}

long kiln_uv_abort(long slot, long gen) {
    if (slot < 0 || slot >= KUV_MAX_SLOTS) {
        return -1;
    }
    kuv_conn *c = kuv_slots[slot];
    if (!c || c->gen != (uint32_t)gen || c->state == KUV_CONN_CLOSING) {
        return -1;
    }
    if (c->awaiting > 0) {
        c->awaiting--;
    }
    kuv_stop_parsing(c);
    c->state = kuv_conn_next(c->state, KUV_CONN_FINISH);
    kuv_sync_read(c);
    kuv_settle(c);
    return 0;
}

long kiln_uv_end(long slot, long gen) {
    if (slot < 0 || slot >= KUV_MAX_SLOTS) {
        return -1;
    }
    kuv_conn *c = kuv_slots[slot];
    if (!c || c->gen != (uint32_t)gen || c->state == KUV_CONN_CLOSING) {
        return -1;
    }
    kuv_stop_parsing(c);
    c->state = kuv_conn_next(c->state, KUV_CONN_FINISH);
    c->body_mode = KUV_BODY_NONE;
    c->body_state = KUV_BODY_IDLE;
    c->parse_state = KUV_PARSE_STOPPED;
    kuv_sync_read(c);
    kuv_settle(c);
    return 0;
}

long kiln_uv_closes_after(long slot, long gen, long stopping) {
    if (slot < 0 || slot >= KUV_MAX_SLOTS) {
        return 1;
    }
    const kuv_conn *c = kuv_slots[slot];
    if (!c || c->gen != (uint32_t)gen || c->state >= KUV_CONN_FLUSHING) {
        return 1;
    }
    if (kuv_keepalive_ms == 0) {
        return 1;
    }
    if (kuv_draining) {
        return c->drain_remaining == 1;
    }
    return stopping && c->pending == 0 && c->awaiting == 1;
}

static int kuv_body_continue(kuv_conn *c) {
    c->expect_state = KUV_EXPECT_NONE;
    if (c->body_state == KUV_BODY_DONE || c->body_len > 0) {
        return 0;
    }
    if (kuv_append(&c->out, &c->out_len, &c->out_cap, KUV_CONTINUE, sizeof(KUV_CONTINUE) - 1) < 0) {
        kuv_close(c);
        return -1;
    }
    kuv_queue_flush(c);
    return 0;
}

static const char *kuv_body_hand(kuv_conn *c, size_t max, int64_t *state) {
    size_t n = c->body_len < max ? c->body_len : max;
    if (n > kuv_take_cap) {
        char *grown = realloc(kuv_take_buf, n);
        if (!grown) {
            state[0] = KUV_TAKE_GONE;
            return "";
        }
        kuv_take_buf = grown;
        kuv_take_cap = n;
    }
    memcpy(kuv_take_buf, c->body, n);
    memmove(c->body, c->body + n, c->body_len - n);
    c->body_len -= n;
    if (c->body_state == KUV_BODY_PAUSED && c->body_len < KUV_BODY_LOW) {
        kuv_body_resume(c);
        kuv_body_pump(c);
    }
    state[0] = KUV_TAKE_DATA;
    sp_ffi_bin_len = (int)n;
    return kuv_take_buf;
}

const char *kiln_uv_body_take(long slot, long gen, long max, int64_t *state) {
    sp_ffi_bin_len = 0;
    kuv_conn *c = kuv_live(slot, gen);
    if (!c || c->body_mode == KUV_BODY_NONE || max <= 0 ||
        (c->expect_state == KUV_EXPECT_STREAMED && kuv_body_continue(c) < 0)) {
        state[0] = KUV_TAKE_GONE;
        return "";
    }
    if (c->body_len > 0) {
        return kuv_body_hand(c, (size_t)max, state);
    }
    if (c->body_error) {
        state[0] = c->body_error == KUV_GONE ? KUV_TAKE_GONE : -c->body_error;
        return "";
    }
    state[0] = c->body_state == KUV_BODY_DONE ? KUV_TAKE_EOF : KUV_TAKE_WAIT;
    kuv_sync_read(c);
    return "";
}

long kiln_uv_body_finish(long slot, long gen, long failed) {
    kuv_conn *c = kuv_live(slot, gen);
    if (!c) {
        return 1;
    }
    if (c->body_mode == KUV_BODY_NONE) {
        return 0;
    }
    if (failed) {
        kuv_stop_parsing(c);
        return 1;
    }
    if (c->body_state == KUV_BODY_DONE && !c->body_error) {
        kuv_body_release(c);
        c->resume_parse = 1;
        return 0;
    }
    int drainable = c->body_mode == KUV_BODY_LENGTH && !c->body_error && !c->read_eof &&
                    c->expect_state != KUV_EXPECT_STREAMED &&
                    c->body_left + (long)c->body_len <= KUV_DRAIN_MAX;
    if (!drainable) {
        kuv_stop_parsing(c);
        return 1;
    }
    c->body_discard = 1;
    c->body_len = 0;
    kuv_body_resume(c);
    kuv_body_pump(c);
    return 0;
}

long kiln_uv_tunnel(long slot, long gen, const char *head, long head_len) {
    kuv_conn *c = kuv_live(slot, gen);
    if (!c || c->body_mode != KUV_BODY_NONE || head_len < 0) {
        return -1;
    }
    if (c->awaiting > 0) {
        c->awaiting--;
    }
    if (head_len > 0 && kuv_append(&c->out, &c->out_len, &c->out_cap, head, (size_t)head_len) < 0) {
        kuv_close(c);
        return -1;
    }
    kuv_release_upgrade(c);
    c->parse_state = KUV_PARSE_TUNNEL;
    kuv_stop_parsing(c);
    c->body_mode = KUV_BODY_TUNNEL;
    c->body_state = c->read_eof ? KUV_BODY_DONE : KUV_BODY_READING;
    c->body_error = 0;
    c->body_len = 0;
    c->head_state = KUV_HEAD_IDLE;
    c->last_active = uv_now(kuv_loop);
    kuv_queue_flush(c);
    kuv_body_pump(c);
    return 0;
}

const char *kiln_uv_tls_alpn(long slot, long gen) {
    sp_ffi_bin_len = 0;
    kuv_conn *c = kuv_live(slot, gen);
    if (!c || !c->tls) {
        return "";
    }
    size_t len = 0;
    const char *proto = kiln_tls_selected(c->tls, &len);
    if (!proto) {
        return "";
    }
    sp_ffi_bin_len = (int)len;
    return proto;
}

const char *kiln_uv_tls_version(long slot, long gen) {
    sp_ffi_bin_len = 0;
    kuv_conn *c = kuv_live(slot, gen);
    if (!c || !c->tls) {
        return "";
    }
    const char *version = kiln_tls_protocol(c->tls);
    sp_ffi_bin_len = version ? (int)strlen(version) : 0;
    return version ? version : "";
}

static void kuv_flush_tls(kuv_conn *c) {
    if (c->tls_wait == 0) {
        for (;;) {
            const char *data = c->tls_pending ? c->tls_pending : c->out;
            size_t len = c->tls_pending ? c->tls_pending_len : c->out_len;
            size_t off = c->tls_pending ? c->tls_pending_off : 0;
            if (len == off) {
                break;
            }
            size_t consumed = 0;
            int rc = kiln_tls_write(c->tls, data + off, len - off, &consumed);
            off += consumed;
            if (rc == KILN_TLS_WANT_READ || rc == KILN_TLS_WANT_WRITE) {
                if (!c->tls_pending) {
                    c->tls_pending = c->out;
                    c->tls_pending_len = c->out_len;
                    c->out = NULL;
                    c->out_len = 0;
                    c->out_cap = 0;
                    c->tls_write_since = uv_now(kuv_loop);
                }
                c->tls_pending_off = off;
                c->tls_wait = rc;
                break;
            }
            if (rc != KILN_TLS_DONE) {
                kuv_close(c);
                return;
            }
            if (c->tls_pending) {
                free(c->tls_pending);
                c->tls_pending = NULL;
                c->tls_pending_len = 0;
                c->tls_pending_off = 0;
                c->tls_write_since = 0;
            } else {
                c->out_len = 0;
                break;
            }
        }
    }
    if (kuv_tls_push(c) < 0) {
        kuv_close(c);
        return;
    }
    if (c->tls_wait == KILN_TLS_WANT_READ) {
        kuv_sync_read(c);
    }
}

static void kuv_flush_plain(kuv_conn *c) {
    uv_buf_t b = uv_buf_init(c->out, (unsigned int)c->out_len);
    int done = c->writes == 0 ? uv_try_write(kuv_stream(c), &b, 1) : 0;
    if (done < 0 && done != UV_EAGAIN) {
        c->out_len = 0;
        kuv_close(c);
        return;
    }
    if (done < 0) {
        done = 0;
    }
    size_t rest = c->out_len - (size_t)done;
    if (rest > 0) {
        char *owned = c->out;
        c->out = NULL;
        c->out_cap = 0;
        if (kuv_queue_write(c, owned, owned + done, rest) < 0) {
            c->out_len = 0;
            kuv_close(c);
            return;
        }
    }
    c->out_len = 0;
    if (rest == 0) {
        kuv_release_idle(c);
    }
}

long kiln_uv_flush(void) {
    long flushed = kuv_flush_count;
    for (long i = 0; i < kuv_flush_count; i++) {
        kuv_conn *c = kuv_flush_list[i];
        c->queued_flush = 0;
        if (c->state == KUV_CONN_CLOSING) {
            continue;
        }
        if (c->out_len > 0 || c->tls) {
            if (c->tls) {
                kuv_flush_tls(c);
            } else {
                kuv_flush_plain(c);
            }
            if (c->state == KUV_CONN_CLOSING) {
                continue;
            }
            kuv_out_resume(c);
        }
        if (c->state == KUV_CONN_FLUSHING && c->writes == 0 && !c->tls_pending) {
            kuv_end(c);
        }
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

long kiln_uv_handshakes(void) {
    return kuv_handshakes;
}

long kiln_uv_stop(void) {
    if (!kuv_listening) {
        return 0;
    }
    kuv_listening = 0;
    uv_close((uv_handle_t *)&kuv_wakeup, NULL);
    uv_timer_stop(&kuv_timer);
    uv_close((uv_handle_t *)&kuv_timer, NULL);
    for (long i = 0; i < kuv_listener_count; i++) {
        if (kuv_listeners[i].open) {
            uv_close((uv_handle_t *)&kuv_listeners[i].h, NULL);
            kuv_listeners[i].open = 0;
        }
    }
    kuv_listener_count = 0;
    for (long i = 0; i < KUV_MAX_SLOTS; i++) {
        if (kuv_slots[i]) {
            kuv_close(kuv_slots[i]);
        }
    }
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
    kuv_draining = 0;
    kuv_handshakes = 0;
    return 0;
}

long kiln_uv_wake(void) {
    return uv_async_send(&kuv_wakeup);
}

long kiln_uv_drain(void) {
    if (!kuv_listening || kuv_draining) {
        return 0;
    }
    kuv_draining = 1;
    for (long i = 0; i < kuv_listener_count; i++) {
        if (kuv_listeners[i].open) {
            uv_close((uv_handle_t *)&kuv_listeners[i].h, NULL);
            kuv_listeners[i].open = 0;
        }
    }
    for (long i = 0; i < KUV_MAX_SLOTS; i++) {
        kuv_conn *c = kuv_slots[i];
        if (!c || c->state == KUV_CONN_CLOSING || c->parse_state == KUV_PARSE_TUNNEL ||
            c->state == KUV_CONN_LINGERING) {
            continue;
        }
        c->drain_remaining = c->pending + c->awaiting;
        kuv_stop_parsing(c);
        kuv_release_upgrade(c);
        if (c->body_mode == KUV_BODY_NONE) {
            c->in_len = 0;
        }
        kuv_sync_read(c);
        if (c->drain_remaining == 0) {
            c->state = kuv_conn_next(c->state, KUV_CONN_FINISH);
            kuv_settle(c);
        }
    }
    return 0;
}

static int kuv_idle(const kuv_conn *c) {
    return c->parse_state != KUV_PARSE_TUNNEL && c->pending == 0 && c->awaiting == 0 &&
           c->out_len == 0 && c->writes == 0;
}

long kiln_uv_busy(void) {
    long busy = kuv_ready;
    for (long i = 0; i < KUV_MAX_SLOTS; i++) {
        kuv_conn *c = kuv_slots[i];
        if (!c || c->state == KUV_CONN_CLOSING) {
            continue;
        }
        if (!kuv_idle(c)) {
            busy++;
        } else if (kuv_draining) {
            kuv_close(c);
        }
    }
    return busy;
}
