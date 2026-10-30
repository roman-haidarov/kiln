#include "kiln_db.h"
#include "../libuv/include/uv.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define DNS_NAME_MAX  253
#define RES_FREE      0
#define RES_PENDING   1
#define RES_RUNNING   2
#define RES_DONE      3
#define RES_FAIL      4
#define RES_CANCELLED 5
#define RES_PREPARING 6

typedef struct {
    uv_getaddrinfo_t req;
    int state;
    int cancel_sent;
    int rfd;
    int wfd;
    uint64_t owner;
    uint32_t generation;
    char host[DNS_NAME_MAX + 1];
    char addr[KILN_DB_HOSTADDR_CAP];
} db_resolve;

static pthread_mutex_t res_mu = PTHREAD_MUTEX_INITIALIZER;
static uv_loop_t res_loop;
static uv_async_t res_wake;
static pthread_t res_thread;
static db_resolve *resolvers;
static uint32_t resolver_queue;

static int res_flags(int fd, int nonblock) {
    int flags = fcntl(fd, F_GETFD);
    if (flags < 0 || fcntl(fd, F_SETFD, flags | FD_CLOEXEC) != 0) {
        return 0;
    }
    if (nonblock) {
        flags = fcntl(fd, F_GETFL);
        if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) != 0) {
            return 0;
        }
    }
    return 1;
}

static void res_drain(int fd) {
    char buffer[64];
    ssize_t n;
    do {
        n = read(fd, buffer, sizeof buffer);
    } while (n > 0 || (n < 0 && errno == EINTR));
}

static int res_signal(int fd) {
    char byte = 1;
    ssize_t n;
    do {
        n = write(fd, &byte, 1);
    } while (n < 0 && errno == EINTR);
    return n == 1;
}

static void res_notify(db_resolve *slot) {
    if (!res_signal(slot->wfd)) {
        slot->state = RES_FAIL;
    }
}

static int res_numeric(const char *host, char *addr, size_t cap) {
    unsigned char ip[16];
    size_t n;
    if (inet_pton(AF_INET, host, ip) != 1 && inet_pton(AF_INET6, host, ip) != 1) {
        return 0;
    }
    n = strlen(host);
    if (n >= cap) {
        return -1;
    }
    memcpy(addr, host, n + 1);
    return 1;
}

static int res_listed(const char *list, size_t used, const char *one, size_t len) {
    size_t start = 0;
    size_t i;
    for (i = 0; i < used; i++) {
        if (list[i] == ',') {
            if (i - start == len && memcmp(list + start, one, len) == 0) {
                return 1;
            }
            start = i + 1;
        }
    }
    return used - start == len && memcmp(list + start, one, len) == 0;
}

static size_t res_collect(struct addrinfo *list, char *out, size_t cap) {
    struct addrinfo *it;
    char one[INET6_ADDRSTRLEN];
    size_t used = 0;
    int count = 0;
    out[0] = 0;
    for (it = list; it && count < KILN_DB_HOSTADDR_MAX; it = it->ai_next) {
        const void *src;
        size_t len;
        if (it->ai_family == AF_INET) {
            src = &((struct sockaddr_in *)it->ai_addr)->sin_addr;
        } else if (it->ai_family == AF_INET6) {
            src = &((struct sockaddr_in6 *)it->ai_addr)->sin6_addr;
        } else {
            continue;
        }
        if (uv_inet_ntop(it->ai_family, src, one, sizeof one) != 0) {
            continue;
        }
        len = strlen(one);
        if (res_listed(out, used, one, len)) {
            continue;
        }
        if (used + (used ? 1 : 0) + len >= cap) {
            break;
        }
        if (used) {
            out[used++] = ',';
        }
        memcpy(out + used, one, len + 1);
        used += len;
        count++;
    }
    return used;
}

static void res_complete(uv_getaddrinfo_t *req, int status, struct addrinfo *list) {
    db_resolve *slot = req->data;
    char addr[KILN_DB_HOSTADDR_CAP];
    size_t got = status == 0 ? res_collect(list, addr, sizeof addr) : 0;
    uv_freeaddrinfo(list);
    pthread_mutex_lock(&res_mu);
    if (slot->state == RES_CANCELLED) {
        slot->state = RES_FREE;
    } else if (slot->state == RES_RUNNING) {
        if (got) {
            memcpy(slot->addr, addr, got + 1);
        }
        slot->state = got ? RES_DONE : RES_FAIL;
        res_notify(slot);
    }
    slot->cancel_sent = 0;
    pthread_mutex_unlock(&res_mu);
}

static void res_dispatch(uv_async_t *handle) {
    uint32_t i;
    (void)handle;
    pthread_mutex_lock(&res_mu);
    for (i = 1; i <= resolver_queue; i++) {
        struct addrinfo hints;
        db_resolve *slot = &resolvers[i];
        int rc;
        if (slot->state == RES_CANCELLED && !slot->cancel_sent) {
            slot->cancel_sent = 1;
            uv_cancel((uv_req_t *)&slot->req);
            continue;
        }
        if (slot->state != RES_PENDING) {
            continue;
        }
        memset(&hints, 0, sizeof hints);
        hints.ai_family = AF_UNSPEC;
        hints.ai_socktype = SOCK_STREAM;
        slot->req.data = slot;
        slot->state = RES_RUNNING;
        rc = uv_getaddrinfo(&res_loop, &slot->req, res_complete, slot->host, NULL, &hints);
        if (rc != 0) {
            slot->state = RES_FAIL;
            res_notify(slot);
        }
    }
    pthread_mutex_unlock(&res_mu);
}

static void *res_main(void *ignored) {
    (void)ignored;
    uv_run(&res_loop, UV_RUN_DEFAULT);
    return NULL;
}

static void res_release_slots(void) {
    uint32_t i;
    if (!resolvers) {
        return;
    }
    for (i = 1; i <= resolver_queue; i++) {
        if (resolvers[i].rfd >= 0) {
            close(resolvers[i].rfd);
        }
        if (resolvers[i].wfd >= 0) {
            close(resolvers[i].wfd);
        }
    }
    free(resolvers);
    resolvers = NULL;
    resolver_queue = 0;
}

int kiln_db_resolver_boot(uint32_t queue) {
    uint32_t i;
    pthread_mutex_lock(&res_mu);
    if (resolvers) {
        int okay = resolver_queue == queue;
        pthread_mutex_unlock(&res_mu);
        return okay ? KILN_DB_OK : KILN_DB_CONFIG;
    }
    if (queue == 0 || queue > 65536) {
        pthread_mutex_unlock(&res_mu);
        return KILN_DB_CONFIG;
    }
    resolvers = calloc((size_t)queue + 1, sizeof *resolvers);
    if (!resolvers) {
        pthread_mutex_unlock(&res_mu);
        return KILN_DB_CAPACITY;
    }
    resolver_queue = queue;
    for (i = 1; i <= queue; i++) {
        resolvers[i].rfd = -1;
        resolvers[i].wfd = -1;
    }
    for (i = 1; i <= queue; i++) {
        int fd[2];
        if (pipe(fd) != 0) {
            break;
        }
        resolvers[i].rfd = fd[0];
        resolvers[i].wfd = fd[1];
        if (!res_flags(fd[0], 1) || !res_flags(fd[1], 1)) {
            break;
        }
    }
    if (i <= queue) {
        res_release_slots();
        pthread_mutex_unlock(&res_mu);
        return KILN_DB_ERR;
    }
    if (uv_loop_init(&res_loop) != 0) {
        res_release_slots();
        pthread_mutex_unlock(&res_mu);
        return KILN_DB_ERR;
    }
    if (uv_async_init(&res_loop, &res_wake, res_dispatch) != 0) {
        uv_loop_close(&res_loop);
        res_release_slots();
        pthread_mutex_unlock(&res_mu);
        return KILN_DB_ERR;
    }
    if (pthread_create(&res_thread, NULL, res_main, NULL) != 0) {
        uv_close((uv_handle_t *)&res_wake, NULL);
        uv_run(&res_loop, UV_RUN_DEFAULT);
        uv_loop_close(&res_loop);
        res_release_slots();
        pthread_mutex_unlock(&res_mu);
        return KILN_DB_ERR;
    }
    pthread_detach(res_thread);
    pthread_mutex_unlock(&res_mu);
    return KILN_DB_OK;
}

static int res_submit(const char *host, size_t host_len, int *wait_fd, char *addr,
    size_t addr_cap, int *done, uint64_t owner, uint64_t *request) {
    char name[DNS_NAME_MAX + 1];
    db_resolve *slot = NULL;
    uint32_t i;
    int numeric;
    if (!wait_fd || !addr || !done || !host || !host_len || host_len > DNS_NAME_MAX ||
        memchr(host, 0, host_len) || !kiln_db_is_ready()) {
        return -KILN_DB_CONFIG;
    }
    *done = 0;
    *wait_fd = -1;
    if (request) {
        *request = 0;
    }
    memcpy(name, host, host_len);
    name[host_len] = 0;
    numeric = res_numeric(name, addr, addr_cap);
    if (numeric == 1) {
        *done = 1;
        return 0;
    }
    if (numeric == -1) {
        return -KILN_DB_CAPACITY;
    }
    if (kiln_db_resolver_boot(kiln_db_limits_get()->max_resolver_queue) != KILN_DB_OK) {
        return -KILN_DB_ERR;
    }
    pthread_mutex_lock(&res_mu);
    for (i = 1; owner && i <= resolver_queue; i++) {
        if (resolvers[i].owner == owner && resolvers[i].state != RES_FREE) {
            pthread_mutex_unlock(&res_mu);
            return -KILN_DB_BUSY;
        }
    }
    for (i = 1; i <= resolver_queue; i++) {
        db_resolve *candidate = &resolvers[i];
        if (candidate->state != RES_FREE) {
            continue;
        }
        slot = candidate;
        slot->state = RES_PREPARING;
        slot->owner = owner;
        if (++slot->generation == 0) {
            slot->generation = 1;
        }
        if (request) {
            *request = ((uint64_t)slot->generation << 32) | i;
        }
        memcpy(slot->host, name, host_len + 1);
        slot->addr[0] = 0;
        *wait_fd = slot->rfd;
        break;
    }
    pthread_mutex_unlock(&res_mu);
    if (!slot) {
        return -KILN_DB_CAPACITY;
    }
    res_drain(slot->rfd);
    pthread_mutex_lock(&res_mu);
    slot->state = RES_PENDING;
    if (uv_async_send(&res_wake) != 0) {
        slot->state = RES_FREE;
        *wait_fd = -1;
        pthread_mutex_unlock(&res_mu);
        return -KILN_DB_ERR;
    }
    pthread_mutex_unlock(&res_mu);
    return (int)i;
}

int kiln_db_resolver_submit(
    const char *host, size_t host_len, int *wait_fd, char *addr, size_t addr_cap, int *done,
    uint64_t *request) {
    if (!request) {
        return -KILN_DB_CONFIG;
    }
    return res_submit(host, host_len, wait_fd, addr, addr_cap, done, 0, request);
}

static int res_take(int id, char *addr, size_t addr_cap, uint64_t owner, uint32_t generation) {
    db_resolve *slot;
    size_t len;
    if (!addr || id <= 0) {
        return KILN_DB_ERR;
    }
    pthread_mutex_lock(&res_mu);
    if (!resolvers || (uint32_t)id > resolver_queue) {
        pthread_mutex_unlock(&res_mu);
        return KILN_DB_ERR;
    }
    slot = &resolvers[id];
    if (slot->owner != owner || slot->generation != generation) {
        pthread_mutex_unlock(&res_mu);
        return KILN_DB_STALE;
    }
    if (slot->state == RES_PENDING || slot->state == RES_RUNNING) {
        pthread_mutex_unlock(&res_mu);
        return KILN_DB_BUSY;
    }
    if (slot->state != RES_DONE) {
        if (slot->state == RES_FAIL) {
            slot->state = RES_FREE;
            slot->owner = 0;
        }
        pthread_mutex_unlock(&res_mu);
        return KILN_DB_ERR;
    }
    len = strlen(slot->addr);
    if (len >= addr_cap) {
        pthread_mutex_unlock(&res_mu);
        return KILN_DB_CAPACITY;
    }
    memcpy(addr, slot->addr, len + 1);
    slot->state = RES_FREE;
    slot->owner = 0;
    pthread_mutex_unlock(&res_mu);
    return KILN_DB_OK;
}

int kiln_db_resolver_take(uint64_t request, char *addr, size_t addr_cap) {
    return res_take((int)(uint32_t)request, addr, addr_cap, 0, (uint32_t)(request >> 32));
}

static void res_cancel(db_resolve *slot) {
    slot->owner = 0;
    switch (slot->state) {
    case RES_PENDING:
        slot->state = RES_FREE;
        break;
    case RES_RUNNING:
        slot->state = RES_CANCELLED;
        uv_async_send(&res_wake);
        break;
    case RES_CANCELLED:
        break;
    default:
        slot->state = RES_FREE;
        break;
    }
}

int kiln_db_resolver_cancel(uint64_t request) {
    db_resolve *slot;
    int id = (int)(uint32_t)request;
    if (id <= 0) {
        return KILN_DB_ERR;
    }
    pthread_mutex_lock(&res_mu);
    if (!resolvers || (uint32_t)id > resolver_queue) {
        pthread_mutex_unlock(&res_mu);
        return KILN_DB_ERR;
    }
    slot = &resolvers[id];
    if (slot->generation != (uint32_t)(request >> 32)) {
        pthread_mutex_unlock(&res_mu);
        return KILN_DB_STALE;
    }
    if (slot->owner) {
        pthread_mutex_unlock(&res_mu);
        return KILN_DB_OWNERSHIP;
    }
    res_cancel(slot);
    pthread_mutex_unlock(&res_mu);
    return KILN_DB_OK;
}

void kiln_db_resolver_cancel_conn(uint64_t handle) {
    uint32_t i;
    if (!handle) {
        return;
    }
    pthread_mutex_lock(&res_mu);
    for (i = 1; i <= resolver_queue; i++) {
        if (resolvers[i].owner == handle) {
            res_cancel(&resolvers[i]);
        }
    }
    pthread_mutex_unlock(&res_mu);
}

int kiln_db_conn_dns_submit(uint64_t handle, uint64_t scope, uint64_t thread_id,
    const char *host, long n, int64_t *out, int len) {
    char addr[KILN_DB_HOSTADDR_CAP];
    int fd = -1;
    int done = 0;
    int id;
    int err = KILN_DB_OK;
    uint64_t request = 0;
    kiln_db_conn *conn;
    if (n <= 0 || !out || len < 3) {
        return KILN_DB_ERR;
    }
    conn = kiln_db_slot_acquire(handle, KILN_DB_SLOT_CONN, scope, thread_id, &err);
    if (!conn) {
        return err;
    }
    id = res_submit(host, (size_t)n, &fd, addr, sizeof addr, &done, handle, &request);
    kiln_db_slot_release(handle, KILN_DB_SLOT_CONN);
    if (id < 0) {
        return -id;
    }
    out[0] = (int64_t)request;
    out[1] = fd;
    out[2] = done;
    return KILN_DB_OK;
}

const char *kiln_db_conn_dns_take(uint64_t handle, uint64_t scope, uint64_t thread_id,
    uint64_t request, int64_t *state, int n) {
    static __thread char addr[KILN_DB_HOSTADDR_CAP];
    int rc;
    int err = KILN_DB_OK;
    kiln_db_conn *conn;
    if (!state || n < 1) {
        return "";
    }
    addr[0] = 0;
    conn = kiln_db_slot_acquire(handle, KILN_DB_SLOT_CONN, scope, thread_id, &err);
    if (!conn) {
        state[0] = err;
        return "";
    }
    rc = res_take((int)(uint32_t)request, addr, sizeof addr, handle, (uint32_t)(request >> 32));
    kiln_db_slot_release(handle, KILN_DB_SLOT_CONN);
    state[0] = rc;
    return addr;
}
