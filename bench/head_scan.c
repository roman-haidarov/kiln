#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include "../ext/kiln_uv_parse.h"

__thread int sp_ffi_bin_len;

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec + (double)t.tv_nsec * 1e-9;
}

static size_t fill(char *buf, size_t cap) {
    const char head[] = "GET / HTTP/1.1\r\nHost: x\r\n";
    size_t len = sizeof head - 1;
    memcpy(buf, head, len);
    while (len + 40 < cap) {
        memcpy(buf + len, "X-Pad: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\r\n", 39);
        len += 39;
    }
    return len;
}

int main(void) {
    static char buf[16384];
    size_t total = fill(buf, sizeof buf);
    int64_t scan[KILN_UV_SCAN_CAP];
    kiln_uv_parse_result result;
    size_t steps[] = {1, 8, 64};
    for (size_t s = 0; s < sizeof steps / sizeof steps[0]; s++) {
        double t = now();
        long incomplete = 0;
        for (size_t len = steps[s]; len <= total; len += steps[s]) {
            if (kiln_uv_parse_request(buf, len, 0, scan, KILN_UV_SCAN_CAP, &result) ==
                KILN_UV_PARSE_INCOMPLETE) {
                incomplete++;
            }
        }
        printf("head_scan bytes_per_read=%zu total_ms=%.3f incomplete=%ld\n", steps[s],
            (now() - t) * 1e3, incomplete);
    }
    for (size_t s = 0; s < sizeof steps / sizeof steps[0]; s++) {
        double t = now();
        long incomplete = 0;
        size_t prev = 0;
        for (size_t len = steps[s]; len <= total; len += steps[s]) {
            if (kiln_uv_parse_request_from(buf, len, prev, 0, scan, KILN_UV_SCAN_CAP, &result) ==
                KILN_UV_PARSE_INCOMPLETE) {
                incomplete++;
            }
            prev = len;
        }
        printf("head_scan_from bytes_per_read=%zu total_ms=%.3f incomplete=%ld\n", steps[s],
            (now() - t) * 1e3, incomplete);
    }
    return 0;
}
