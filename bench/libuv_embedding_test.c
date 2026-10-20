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

enum {
    TEST_HEADER_TIMEOUT_MS = 30,
    TEST_TIMER_POLL_MS = 10,
    TEST_TIMER_BUDGET_MS = 1000
};

extern long kiln_uv_configure(const int64_t *, long);
extern long kiln_uv_adopt(long, long);
extern long kiln_uv_start(void);
extern long kiln_uv_stop(void);
extern long kiln_uv_fd(void);
extern long kiln_uv_poll(void);
extern long kiln_uv_settle(void);
extern long kiln_uv_timeout(void);
extern long kiln_uv_wake(void);
extern const char *kiln_uv_next(int64_t *, long, int64_t *);
extern long kiln_uv_send(long, long, const char *, long, const char *, long, long);
extern long kiln_uv_flush(void);

static double now_seconds(void) {
    struct timespec ts;
    assert(clock_gettime(CLOCK_MONOTONIC, &ts) == 0);
    return ts.tv_sec + ts.tv_nsec / 1000000000.0;
}

static void poll_backend(long max_ms) {
    int fd = (int)kiln_uv_fd();
    assert(fd >= 0);
    long ms = kiln_uv_timeout();
    if (ms < 0 || ms > max_ms) {
        ms = max_ms;
    }
    fd_set fds;
    FD_ZERO(&fds);
    FD_SET(fd, &fds);
    struct timeval tv = {ms / 1000, (ms % 1000) * 1000};
    int rc = select(fd + 1, &fds, NULL, NULL, &tv);
    assert(rc >= 0 || errno == EINTR);
}

static void *waker(void *arg) {
    (void)arg;
    struct timespec ts = {0, 15000000};
    nanosleep(&ts, NULL);
    assert(kiln_uv_wake() == 0);
    return NULL;
}

int main(void) {
    static const int64_t cfg[] = {256, 1024 * 1024, TEST_HEADER_TIMEOUT_MS, 40, 500, 1000, 50, 1, 256, 128};
    static const char request[] = "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    static const char head[] = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n";

    for (int repeat = 0; repeat < 5; repeat++) {
        int listener = socket(AF_INET, SOCK_STREAM, 0);
        assert(listener >= 0);
        int reuse = 1;
        assert(setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof reuse) == 0);
        struct sockaddr_in address = {.sin_family = AF_INET, .sin_port = 0};
        address.sin_addr.s_addr = htonl(0x7f000001u);
        assert(bind(listener, (struct sockaddr *)&address, sizeof address) == 0);
        assert(listen(listener, 128) == 0);
        socklen_t address_len = sizeof address;
        assert(getsockname(listener, (struct sockaddr *)&address, &address_len) == 0);
        assert(kiln_uv_configure(cfg, 10) == 0);
        assert(kiln_uv_adopt(listener, -1) == 0);
        assert(kiln_uv_start() == 0);
        assert(kiln_uv_settle() == 1);
        assert(kiln_uv_settle() == 0);
        assert(kiln_uv_timeout() >= 0);

        pthread_t worker;
        assert(pthread_create(&worker, NULL, waker, NULL) == 0);
        double wake_start = now_seconds();
        poll_backend(200);
        assert(now_seconds() - wake_start < 0.15);
        assert(pthread_join(worker, NULL) == 0);
        kiln_uv_poll();

        int client = socket(AF_INET, SOCK_STREAM, 0);
        assert(client >= 0);
        assert(connect(client, (struct sockaddr *)&address, sizeof address) == 0);
        assert(send(client, request, sizeof request - 1, 0) == sizeof request - 1);
        assert(fcntl(client, F_SETFL, fcntl(client, F_GETFL) | O_NONBLOCK) == 0);
        double begin = now_seconds();
        char received[256] = {0};
        size_t got = 0;
        int delivered = 0;
        while (now_seconds() - begin < 0.2 && got < sizeof received - 1) {
            kiln_uv_poll();
            int64_t scan[1024];
            int64_t meta[8];
            if (!delivered) {
                const char *src = kiln_uv_next(scan, 1024, meta);
                if (src && sp_ffi_bin_len > 0) {
                    assert(kiln_uv_send(meta[3], meta[4], head, sizeof head - 1, "OK", 2, 1) == 0);
                    delivered = 1;
                }
            }
            kiln_uv_flush();
            kiln_uv_settle();
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
            poll_backend(200);
        }
        assert(delivered);
        assert(strstr(received, "HTTP/1.1 200 OK") != NULL);
        assert(strstr(received, "\r\n\r\nOK") != NULL);
        assert(now_seconds() - begin < 0.2);
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
            kiln_uv_poll();
            kiln_uv_settle();
            kiln_uv_flush();
            ssize_t count = recv(slow, timed + size, sizeof timed - size - 1, 0);
            if (count > 0) {
                size += (size_t)count;
            } else if (count == 0) {
                peer_closed = 1;
                break;
            } else {
                assert(errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR);
            }
            poll_backend(TEST_TIMER_POLL_MS);
        }
        if (!strstr(timed, "408 Request Timeout")) {
            fprintf(stderr,
                "header timeout smoke failed: elapsed=%.1f ms, received=%zu bytes, "
                "peer_closed=%d, next_uv_timeout=%ld ms, response=%s\n",
                (now_seconds() - begin) * 1000, size, peer_closed, kiln_uv_timeout(), timed);
        }
        assert(strstr(timed, "408 Request Timeout") != NULL);
        close(slow);
        assert(kiln_uv_stop() == 0);
        printf("ok libuv 1.53 embedding iteration %d\n", repeat + 1);
    }
}
