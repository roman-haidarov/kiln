#define _GNU_SOURCE
#include <arpa/inet.h>
#include <assert.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static void *open_address;
static void *refusing_address;
static pthread_mutex_t audit_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t audit_cond = PTHREAD_COND_INITIALIZER;
static int delayed;
static int continue_first;
static long audit_add(void *pointer, long delta, int order) {
    long value = __atomic_add_fetch((long *)pointer, delta, order);
    if (pointer == open_address && delta == 1 && value == 2) {
        pthread_mutex_lock(&audit_lock);
        delayed = 1;
        pthread_cond_broadcast(&audit_cond);
        while (!continue_first)
            pthread_cond_wait(&audit_cond, &audit_lock);
        pthread_mutex_unlock(&audit_lock);
    }
    if (pointer == refusing_address && delta == 1) {
        pthread_mutex_lock(&audit_lock);
        continue_first = 1;
        pthread_cond_broadcast(&audit_cond);
        pthread_mutex_unlock(&audit_lock);
    }
    return value;
}
#define __atomic_add_fetch(pointer, delta, order) audit_add((void *)(pointer), (delta), (order))
#include "../ext/kiln_uv.c"
#undef __atomic_add_fetch
__thread int sp_ffi_bin_len;
static long loops[2];
static int pending_ready;
static int pending_go;
static int pending_won;
static long pending_max_requests;
static long pending_max_bytes;
static void *pending_worker(void *arg) {
    long handle = loops[(intptr_t)arg % 2];
    int reserved = kiln_uv_pending_reserve(handle, pending_max_requests, pending_max_bytes, 32);
    pthread_mutex_lock(&audit_lock);
    pending_ready++;
    pending_won += reserved;
    pthread_cond_broadcast(&audit_cond);
    while (!pending_go)
        pthread_cond_wait(&audit_cond, &audit_lock);
    pthread_mutex_unlock(&audit_lock);
    if (reserved)
        kiln_uv_pending_release(handle, 32);
    return NULL;
}
static void pending_case(long max_requests, long max_bytes, int expected) {
    pthread_t threads[12];
    pending_ready = pending_go = pending_won = 0;
    pending_max_requests = max_requests;
    pending_max_bytes = max_bytes;
    for (intptr_t i = 0; i < 12; i++)
        assert(pthread_create(&threads[i], NULL, pending_worker, (void *)i) == 0);
    pthread_mutex_lock(&audit_lock);
    while (pending_ready != 12)
        pthread_cond_wait(&audit_cond, &audit_lock);
    assert(pending_won == expected);
    assert(kiln_uv_pending_requests(loops[0]) == expected);
    assert(kiln_uv_pending_bytes(loops[1]) == expected * 32);
    pending_go = 1;
    pthread_cond_broadcast(&audit_cond);
    pthread_mutex_unlock(&audit_lock);
    for (int i = 0; i < 12; i++)
        assert(pthread_join(threads[i], NULL) == 0);
    assert(kiln_uv_pending_requests(loops[1]) == 0);
    assert(kiln_uv_pending_bytes(loops[0]) == 0);
}
static void *poll_first(void *unused) {
    (void)unused;
    kiln_uv_poll(loops[0]);
    return NULL;
}
static void *poll_second(void *unused) {
    (void)unused;
    pthread_mutex_lock(&audit_lock);
    while (!delayed)
        pthread_cond_wait(&audit_cond, &audit_lock);
    pthread_mutex_unlock(&audit_lock);
    kiln_uv_poll(loops[1]);
    return NULL;
}
int main(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    assert(fd >= 0);
    struct sockaddr_in address = {
        .sin_family = AF_INET, .sin_addr.s_addr = htonl(0x7f000001u), .sin_port = 0};
    assert(bind(fd, (struct sockaddr *)&address, sizeof address) == 0);
    assert(listen(fd, 128) == 0);
    socklen_t size = sizeof address;
    assert(getsockname(fd, (struct sockaddr *)&address, &size) == 0);
    int64_t cfg[] = {1, 1048576, 5000, 5000, 5000, 10000, 1000, 1, 256, 128};
    long group = kiln_uv_group_new();
    for (int i = 0; i < 2; i++) {
        loops[i] = kiln_uv_create();
        assert(kiln_uv_join(loops[i], group, 1) == 0);
        assert(kiln_uv_configure(loops[i], cfg, 10) == 0);
        assert(kiln_uv_adopt(loops[i], dup(fd), -1) == 0);
        assert(kiln_uv_start(loops[i]) == 0);
    }
    int clients[3];
    clients[0] = socket(AF_INET, SOCK_STREAM, 0);
    assert(connect(clients[0], (struct sockaddr *)&address, sizeof address) == 0);
    kiln_uv_poll(loops[0]);
    kuv_group *g = (kuv_group *)(intptr_t)group;
    assert(g->open == 1);
    for (int i = 1; i < 3; i++) {
        clients[i] = socket(AF_INET, SOCK_STREAM, 0);
        assert(connect(clients[i], (struct sockaddr *)&address, sizeof address) == 0);
    }
    open_address = &g->open;
    refusing_address = &g->refusing;
    pthread_t threads[2];
    assert(pthread_create(&threads[0], NULL, poll_first, NULL) == 0);
    assert(pthread_create(&threads[1], NULL, poll_second, NULL) == 0);
    for (int i = 0; i < 2; i++)
        assert(pthread_join(threads[i], NULL) == 0);
    long serving = 0;
    for (int j = 0; j < 2; j++) {
        kuv_context *ctx = (kuv_context *)(intptr_t)loops[j];
        for (int i = 0; i < KUV_MAX_SLOTS; i++) {
            if (ctx->slots[i] && !ctx->slots[i]->over_limit)
                serving++;
        }
    }
    printf("max_conns=1 physical_open=%ld refusing=%ld serving_objects=%ld\n", g->open, g->refusing,
        serving);
    assert(serving == 1);
    open_address = NULL;
    refusing_address = NULL;
    for (int i = 0; i < 50; i++) {
        pending_case(3, 1024, 3);
        pending_case(12, 96, 3);
    }
    assert(kiln_uv_pending_reserve(loops[0], 3, 96, -1) == 0);
    assert(kiln_uv_pending_reserve(loops[0], 3, 96, LONG_MAX) == 0);
    assert(kiln_uv_pending_requests(loops[0]) == 0);
    assert(kiln_uv_pending_bytes(loops[1]) == 0);
    puts("pending budget: count/byte bounds and rollback passed across two loops and 12 threads");
    for (int i = 0; i < 3; i++)
        close(clients[i]);
    close(fd);
    for (int i = 0; i < 2; i++) {
        kiln_uv_stop(loops[i]);
        assert(kiln_uv_destroy(loops[i]) == 0);
    }
    kiln_uv_group_release(group);
    return 0;
}
