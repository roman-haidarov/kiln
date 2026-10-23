#ifndef KILN_UV_PARSE_H
#define KILN_UV_PARSE_H

#include <stddef.h>
#include <stdint.h>
#include "kiln_http_scan.h"

#define KILN_UV_HEAD_MAX    KILN_HTTP_HEAD_MAX
#define KILN_UV_MAX_HEADERS KILN_HTTP_MAX_HEADERS
#define KILN_UV_STRIDE      KILN_HTTP_SCAN_STRIDE
#define KILN_UV_SCAN_CAP    KILN_HTTP_SCAN_CAP

enum { KILN_UV_PARSE_INCOMPLETE, KILN_UV_PARSE_COMPLETE, KILN_UV_PARSE_ERROR };

typedef struct {
    size_t head_len;
    size_t total_len;
    long body_len;
    long nheaders;
    int minor;
    int has_close;
    int has_keep;
    int expect_continue;
    int error_status;
    int streamed;
    int chunked;
    int upgrade;
} kiln_uv_parse_result;

enum {
    KILN_UV_CHUNK_SIZE,
    KILN_UV_CHUNK_DATA,
    KILN_UV_CHUNK_DATA_END,
    KILN_UV_CHUNK_TRAILER,
    KILN_UV_CHUNK_DONE
};

enum {
    KILN_UV_CHUNK_MORE = 0,
    KILN_UV_CHUNK_END = 1,
    KILN_UV_CHUNK_BAD = -1,
    KILN_UV_CHUNK_TOO_BIG = -2,
    KILN_UV_CHUNK_HUGE = -3
};

typedef struct {
    int phase;
    long left;
    long excess;
    long trailer;
} kiln_uv_chunk_state;

void kiln_uv_chunk_init(kiln_uv_chunk_state *state);
int kiln_uv_chunk_decode(kiln_uv_chunk_state *state, const char *in, size_t in_len, char *out,
    size_t out_cap, size_t *consumed, size_t *produced);

const char *kiln_chunk_step(const char *data, long total, long start, long max, int64_t *state);

int kiln_uv_parse_request_from(const char *data, size_t len, size_t scan_from, long max_body,
    int64_t *scan, long cap, kiln_uv_parse_result *result);
int kiln_uv_parse_request(const char *data, size_t len, long max_body, int64_t *scan, long cap,
    kiln_uv_parse_result *result);

#endif
