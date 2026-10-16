#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

__thread int sp_ffi_bin_len;

long kiln_http_scan(const char *head, long len, int64_t *out, long cap);
const char *kiln_recv(long fd, long max);
long kiln_recv_status(void);

static void *kiln_tsan_worker(void *argument) {
    intptr_t worker = (intptr_t)argument;
    int pair[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair) != 0)
        return (void *)1;
    for (long i = 0; i < 2048; i++) {
        char request[128];
        char message[64];
        int request_len = snprintf(request, sizeof request,
            "GET /worker-%ld-%ld HTTP/1.1\r\nHost: example.test", (long)worker, i);
        int64_t out[505];
        if (request_len <= 0 || kiln_http_scan(request, request_len, out, 505) != 1) {
            close(pair[0]);
            close(pair[1]);
            return (void *)1;
        }
        int message_len = snprintf(message, sizeof message, "%ld:%ld", (long)worker, i);
        if (message_len <= 0 || write(pair[0], message, (size_t)message_len) != message_len) {
            close(pair[0]);
            close(pair[1]);
            return (void *)1;
        }
        const char *received = kiln_recv(pair[1], sizeof message);
        if (kiln_recv_status() != message_len || sp_ffi_bin_len != message_len ||
            memcmp(received, message, (size_t)message_len) != 0) {
            close(pair[0]);
            close(pair[1]);
            return (void *)1;
        }
    }
    close(pair[0]);
    close(pair[1]);
    return NULL;
}

int main(void) {
    pthread_t workers[2];
    for (intptr_t i = 0; i < 2; i++)
        if (pthread_create(&workers[i], NULL, kiln_tsan_worker, (void *)i) != 0)
            return 1;
    int failed = 0;
    for (long i = 0; i < 2; i++) {
        void *result = NULL;
        if (pthread_join(workers[i], &result) != 0 || result)
            failed = 1;
    }
    if (failed)
        return 1;
    puts("native C TSan: 2 threads, parser and thread-local recv state passed");
    return 0;
}
