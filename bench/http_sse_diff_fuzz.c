#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include "picohttpparser/picohttpparser.h"

int kiln_phr_parse_request_sse42(const char *buf, size_t len, const char **method,
    size_t *method_len, const char **path, size_t *path_len, int *minor_version,
    struct phr_header *headers, size_t *num_headers, size_t last_len);

static void kiln_sse_compare(const uint8_t *data, size_t size, int require_parse) {
    const char *m1 = NULL;
    const char *m2 = NULL;
    const char *p1 = NULL;
    const char *p2 = NULL;
    size_t ml1 = 0;
    size_t ml2 = 0;
    size_t pl1 = 0;
    size_t pl2 = 0;
    int v1 = -1;
    int v2 = -1;
    struct phr_header a[128];
    struct phr_header b[128];
    size_t an = 128;
    size_t bn = 128;
    int r1 = phr_parse_request((const char *)data, size, &m1, &ml1, &p1, &pl1, &v1, a, &an, 0);
    int r2 = kiln_phr_parse_request_sse42(
        (const char *)data, size, &m2, &ml2, &p2, &pl2, &v2, b, &bn, 0);
    if (r1 != r2)
        abort();
    if (require_parse && r1 <= 0)
        abort();
    if (r1 <= 0)
        return;
    if (v1 != v2 || ml1 != ml2 || pl1 != pl2 || an != bn || m1 != m2 || p1 != p2)
        abort();
    for (size_t i = 0; i < an; i++) {
        if (a[i].name != b[i].name || a[i].name_len != b[i].name_len || a[i].value != b[i].value ||
            a[i].value_len != b[i].value_len)
            abort();
    }
}

int LLVMFuzzerInitialize(int *argc, char ***argv) {
    (void)argc;
    (void)argv;
    static const char get[] = "GET / HTTP/1.1\r\nHost: example.test\r\nAccept: */*\r\n\r\n";
    static const char post[] =
        "POST /items HTTP/1.1\r\nHost: example.test\r\nContent-Length: 4\r\n\r\ndata";
    kiln_sse_compare((const uint8_t *)get, sizeof get - 1, 1);
    kiln_sse_compare((const uint8_t *)post, sizeof post - 1, 1);
    return 0;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (!data || size == 0 || size > 16384)
        return 0;
    kiln_sse_compare(data, size, 0);
    return 0;
}
