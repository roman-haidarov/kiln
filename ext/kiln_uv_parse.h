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
} kiln_uv_parse_result;

int kiln_uv_parse_request(const char *data, size_t len, long max_body, int64_t *scan, long cap,
    kiln_uv_parse_result *result);

#endif
