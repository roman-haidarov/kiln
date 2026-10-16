#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../ext/kiln_uv_parse.h"

__thread int sp_ffi_bin_len;

long kiln_http_scan(const char *head, long len, int64_t *out, long cap);
long kiln_scan_request_head(const char *buf, long len, int64_t *out, long cap);
long kiln_chunk_size(const char *text, long len, long max);
long kiln_token(const char *text, long len);
long kiln_ctl(const char *text, long len);
long kiln_digits(const char *text, long len);
long kiln_host(const char *text, long len);
long kiln_http_accepts_gzip(const char *text, long len);

enum { SEED_MAX = 65536 };

static const char *corpus_root;
static char seed[SEED_MAX];
static int64_t scan[KILN_UV_SCAN_CAP];
static int failures;

static long load(const char *dir, const char *name) {
    char path[4096];
    snprintf(path, sizeof path, "%s/%s/%s", corpus_root, dir, name);
    FILE *file = fopen(path, "rb");
    if (!file) {
        fprintf(stderr, "seed check: cannot open %s\n", path);
        failures++;
        return -1;
    }
    size_t len = fread(seed, 1, sizeof seed, file);
    int truncated = len == sizeof seed && fgetc(file) != EOF;
    fclose(file);
    if (truncated) {
        fprintf(stderr, "seed check: %s is larger than %d bytes\n", path, SEED_MAX);
        failures++;
        return -1;
    }
    return (long)len;
}

static void expect(int passed, const char *dir, const char *name, const char *what) {
    if (!passed) {
        fprintf(stderr, "seed check: %s/%s: %s\n", dir, name, what);
        failures++;
    }
}

static void check_scan(const char *name) {
    long len = load("http-kind-0", name);
    if (len < 0)
        return;
    long count = kiln_http_scan(seed, len, scan, KILN_UV_SCAN_CAP);
    expect(count >= 1, "http-kind-0", name, "request head does not parse");
    expect(count < 0 || (scan[4] & 1) == 1, "http-kind-0", name, "request is not HTTP/1.1");
}

static void check_helper(
    const char *dir, const char *name, long (*helper)(const char *, long), long wanted) {
    long len = load(dir, name);
    if (len >= 0)
        expect(helper(seed, len) == wanted, dir, name, "helper result differs");
}

static void check_chunk(void) {
    long len = load("http-kind-1", "size");
    if (len >= 0)
        expect(kiln_chunk_size(seed, len, 1024 * 1024) == 1024 * 1024, "http-kind-1", "size",
            "chunk size differs");
}

static int parse_event(const char *name, long max_body, kiln_uv_parse_result *result) {
    long len = load("uv-parse", name);
    if (len < 1) {
        if (len == 0)
            expect(0, "uv-parse", name, "seed is empty");
        return -2;
    }
    expect(seed[0] % 6 == 4, "uv-parse", name, "selector byte does not choose max_body 1 MiB");
    return kiln_uv_parse_request(
        seed + 1, (size_t)len - 1, max_body, scan, KILN_UV_SCAN_CAP, result);
}

static void check_event(const char *name, int state, int status) {
    kiln_uv_parse_result result;
    int got = parse_event(name, 1024 * 1024, &result);
    if (got == -2)
        return;
    expect(got == state, "uv-parse", name, "parse state differs");
    expect(state != KILN_UV_PARSE_ERROR || result.error_status == status, "uv-parse", name,
        "error status differs");
}

static void check_event_details(void) {
    kiln_uv_parse_result result;
    if (parse_event("request", 1024 * 1024, &result) == KILN_UV_PARSE_COMPLETE)
        expect(result.body_len == 4 && result.has_close && result.has_keep &&
                   result.nheaders == 3 && result.total_len == result.head_len + 8,
            "uv-parse", "request", "parsed fields differ");
    if (parse_event("expect", 1024 * 1024, &result) == KILN_UV_PARSE_INCOMPLETE)
        expect(result.expect_continue == 1, "uv-parse", "expect", "100-continue not reported");
    if (parse_event("request", 3, &result) != -2)
        expect(result.error_status == 413, "uv-parse", "request", "max_body 3 does not give 413");
}

static void check_limits(void) {
    static char head[KILN_UV_HEAD_MAX + 4];
    static const char start[] = "GET / HTTP/1.1\r\nHost: example.test\r\nX-Fill: ";
    size_t prefix = sizeof(start) - 1;
    memcpy(head, start, prefix);
    memset(head + prefix, 'a', KILN_UV_HEAD_MAX - prefix);
    memcpy(head + KILN_UV_HEAD_MAX, "\r\n\r\n", 4);
    kiln_uv_parse_result result;
    expect(kiln_uv_parse_request(head, sizeof head, 0, scan, KILN_UV_SCAN_CAP, &result) ==
               KILN_UV_PARSE_COMPLETE,
        "limits", "head", "a head of exactly KILN_UV_HEAD_MAX bytes is rejected");
    expect(kiln_scan_request_head(head, KILN_UV_HEAD_MAX, scan, KILN_UV_SCAN_CAP - 1) == -1,
        "limits", "scan", "kiln_http.c accepts a scan buffer below KILN_UV_SCAN_CAP");
    expect(kiln_scan_request_head(head, KILN_UV_HEAD_MAX, scan, KILN_UV_SCAN_CAP) == 2, "limits",
        "scan", "kiln_http.c rejects a scan buffer of KILN_UV_SCAN_CAP");
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s CORPUS_ROOT\n", argv[0]);
        return 2;
    }
    corpus_root = argv[1];
    check_scan("get");
    check_scan("post");
    check_chunk();
    check_helper("http-kind-2", "quality", kiln_http_accepts_gzip, 1);
    check_helper("http-kind-3", "token", kiln_token, 1);
    check_helper("http-kind-4", "control", kiln_ctl, 0);
    check_helper("http-kind-5", "content_length", kiln_digits, 1);
    check_helper("http-kind-6", "host", kiln_host, 1);
    check_event("request", KILN_UV_PARSE_COMPLETE, 0);
    check_event("expect", KILN_UV_PARSE_INCOMPLETE, 0);
    check_event("bad_expect", KILN_UV_PARSE_ERROR, 417);
    check_event("unsupported", KILN_UV_PARSE_ERROR, 501);
    check_event("invalid_length", KILN_UV_PARSE_ERROR, 400);
    check_event("oversized", KILN_UV_PARSE_ERROR, 413);
    check_event("oversized-head", KILN_UV_PARSE_ERROR, 431);
    check_event_details();
    check_limits();
    return failures ? 1 : 0;
}
