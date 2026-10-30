#define _POSIX_C_SOURCE 200809L
#include <arpa/inet.h>
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

__thread int sp_ffi_bin_len;

enum { TEST_HEADER_TIMEOUT_MS = 30, TEST_TIMER_POLL_MS = 10, TEST_TIMER_BUDGET_MS = 5000 };

extern long kiln_uv_create(void);
extern long kiln_uv_destroy(long);
extern long kiln_uv_configure(long, const int64_t *, long);
extern long kiln_uv_adopt(long, long, long);
extern long kiln_uv_start(long);
extern long kiln_uv_stop(long);
extern long kiln_uv_abort(long, long, long);
extern long kiln_uv_fd(long);
extern long kiln_uv_poll(long);
extern long kiln_uv_settle(long);
extern long kiln_uv_timeout(long);
extern long kiln_uv_wake(long);
extern const char *kiln_uv_next(long, int64_t *, long, int64_t *);
extern long kiln_uv_send(long, long, long, const char *, long, const char *, long, long);
extern long kiln_uv_flush(long);

static double now_seconds(void) {
    struct timespec ts;
    assert(clock_gettime(CLOCK_MONOTONIC, &ts) == 0);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1000000000.0;
}

static int poll_fd(long context, long ms) {
    int fd = (int)kiln_uv_fd(context);
    assert(fd >= 0);
    if (ms < 0) {
        ms = 0;
    }
    for (;;) {
        fd_set fds;
        FD_ZERO(&fds);
        FD_SET(fd, &fds);
        struct timeval tv = {(time_t)(ms / 1000), (suseconds_t)((ms % 1000) * 1000)};
        int rc = select(fd + 1, &fds, NULL, NULL, &tv);
        if (rc < 0 && errno == EINTR) {
            continue;
        }
        assert(rc >= 0);
        return rc > 0 && FD_ISSET(fd, &fds);
    }
}

static int poll_backend(long context, long max_ms) {
    long ms = kiln_uv_timeout(context);
    if (ms < 0 || ms > max_ms) {
        ms = max_ms;
    }
    return poll_fd(context, ms);
}

static void *waker(void *arg) {
    long context = (long)(intptr_t)arg;
    struct timespec ts = {0, 15000000};
    nanosleep(&ts, NULL);
    assert(kiln_uv_wake(context) == 0);
    return NULL;
}

static void *run_embedding(void *arg) {
    (void)arg;
    static const int64_t cfg[] = {
        256, 1024L * 1024L, TEST_HEADER_TIMEOUT_MS, 40, 500, 1000, 50, 1, 256, 128};
    static const char request[] = "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    static const char head[] = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n";

    int64_t previous_gen = 0;
    int64_t previous_slot = -1;
    for (int repeat = 0; repeat < 5; repeat++) {
        long context = kiln_uv_create();
        assert(context != 0);
        int listener = socket(AF_INET, SOCK_STREAM, 0);
        assert(listener >= 0);
        int reuse = 1;
        assert(setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof reuse) == 0);
        struct sockaddr_in address = {.sin_family = AF_INET, .sin_port = 0};
        address.sin_addr.s_addr = htonl(0x7f000001u);
        if (bind(listener, (struct sockaddr *)&address, sizeof address) != 0) {
            perror("bind");
            return (void *)(intptr_t)1;
        }
        assert(listen(listener, 128) == 0);
        socklen_t address_len = sizeof address;
        assert(getsockname(listener, (struct sockaddr *)&address, &address_len) == 0);
        assert(kiln_uv_configure(context, cfg, 10) == 0);
        assert(kiln_uv_adopt(context, listener, -1) == 0);
        assert(kiln_uv_start(context) == 0);
        assert(kiln_uv_settle(context) == 1);
        assert(kiln_uv_settle(context) == 0);
        assert(kiln_uv_timeout(context) >= 0);

        pthread_t worker;
        assert(pthread_create(&worker, NULL, waker, (void *)(intptr_t)context) == 0);
        double wake_start = now_seconds();
        int woke = 0;
        do {
            long ms = kiln_uv_timeout(context);
            if (ms < 50) {
                ms = 50;
            }
            if (poll_fd(context, ms)) {
                woke = 1;
                break;
            }
        } while (now_seconds() - wake_start < 5.0);
        assert(woke);
        assert(pthread_join(worker, NULL) == 0);
        kiln_uv_poll(context);

        int client = socket(AF_INET, SOCK_STREAM, 0);
        assert(client >= 0);
        assert(connect(client, (struct sockaddr *)&address, sizeof address) == 0);
        assert(send(client, request, sizeof request - 1, 0) == sizeof request - 1);
        assert(fcntl(client, F_SETFL, fcntl(client, F_GETFL) | O_NONBLOCK) == 0);
        double begin = now_seconds();
        char received[256] = {0};
        size_t got = 0;
        int delivered = 0;
        while (now_seconds() - begin < 5.0 && got < sizeof received - 1) {
            kiln_uv_poll(context);
            int64_t scan[1024];
            int64_t meta[8];
            if (!delivered) {
                const char *src = kiln_uv_next(context, scan, 1024, meta);
                if (src && sp_ffi_bin_len > 0) {
                    assert(meta[4] > UINT32_MAX);
                    if (previous_gen != 0) {
                        assert(meta[3] == previous_slot);
                        assert(meta[4] != previous_gen);
                        assert(kiln_uv_abort(context, meta[3], previous_gen) < 0);
                    }
                    previous_slot = meta[3];
                    previous_gen = meta[4];
                    assert(kiln_uv_send(context, meta[3], meta[4], head, sizeof head - 1, "OK", 2, 1) == 0);
                    delivered = 1;
                }
            }
            kiln_uv_flush(context);
            kiln_uv_settle(context);
            ssize_t count = recv(client, received + got, sizeof received - got - 1, 0);
            if (count > 0) {
                got += (size_t)count;
            } else if (count == 0) {
                break;
            } else {
                assert(errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR);
            }
            if (strstr(received, "\r\n\r\nOK")) {
                break;
            }
            poll_backend(context, 200);
        }
        assert(delivered);
        assert(strstr(received, "HTTP/1.1 200 OK") != NULL);
        assert(strstr(received, "\r\n\r\nOK") != NULL);
        close(client);

        int slow = socket(AF_INET, SOCK_STREAM, 0);
        assert(slow >= 0);
        assert(connect(slow, (struct sockaddr *)&address, sizeof address) == 0);
        static const char incomplete[] = "GET / HTTP/1.1\r\nHost: localhost\r\n";
        assert(send(slow, incomplete, sizeof incomplete - 1, 0) == sizeof incomplete - 1);
        assert(fcntl(slow, F_SETFL, fcntl(slow, F_GETFL) | O_NONBLOCK) == 0);
        char timed[256] = {0};
        size_t size = 0;
        int peer_closed = 0;
        begin = now_seconds();
        while (now_seconds() - begin < TEST_TIMER_BUDGET_MS / 1000.0 &&
               !strstr(timed, "408 Request Timeout")) {
            kiln_uv_poll(context);
            kiln_uv_settle(context);
            kiln_uv_flush(context);
            ssize_t count = recv(slow, timed + size, sizeof timed - size - 1, 0);
            if (count > 0) {
                size += (size_t)count;
            } else if (count == 0) {
                peer_closed = 1;
                break;
            } else {
                assert(errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR);
            }
            poll_backend(context, TEST_TIMER_POLL_MS);
        }
        if (!strstr(timed, "408 Request Timeout")) {
            fprintf(stderr,
                "header timeout smoke failed: elapsed=%.1f ms, received=%zu bytes, "
                "peer_closed=%d, next_uv_timeout=%ld ms, response=%s\n",
                (now_seconds() - begin) * 1000, size, peer_closed, kiln_uv_timeout(context), timed);
        }
        assert(strstr(timed, "408 Request Timeout") != NULL);
        close(slow);
        assert(kiln_uv_stop(context) == 0);
        assert(kiln_uv_destroy(context) == 0);
        printf("ok libuv 1.53 embedding iteration %d\n", repeat + 1);
    }
    return NULL;
}

int main(void) {
    pthread_t threads[4];
    for (int i = 0; i < 4; i++) {
        assert(pthread_create(&threads[i], NULL, run_embedding, NULL) == 0);
    }
    for (int i = 0; i < 4; i++) {
        void *result = NULL;
        assert(pthread_join(threads[i], &result) == 0);
        assert(result == NULL);
    }
}
