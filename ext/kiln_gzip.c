#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "spinel/runtime.h"
#include "zlib-ng/zlib-ng.h"

#define KILN_GZIP_ERROR  "Kiln::CompressError"
#define KILN_GZIP_WINDOW 31
#define KILN_GZIP_MEMORY 8

typedef struct {
    char *p;
    size_t len;
    size_t cap;
} kiln_gz_out;

static int kiln_gz_level(sp_int level) {
    if (level < 1)
        return 1;
    if (level > 9)
        return 9;
    return (int)level;
}

static zng_stream *kiln_gz_new(sp_int level) {
    zng_stream *z = calloc(1, sizeof *z);
    if (!z)
        return NULL;
    if (zng_deflateInit2(z, kiln_gz_level(level), Z_DEFLATED, KILN_GZIP_WINDOW, KILN_GZIP_MEMORY,
            Z_DEFAULT_STRATEGY) != Z_OK) {
        free(z);
        return NULL;
    }
    return z;
}

static int kiln_gz_grow(kiln_gz_out *out, size_t want) {
    if (out->cap >= want)
        return 1;
    size_t cap = out->cap ? out->cap : 256;
    while (cap < want)
        cap *= 2;
    char *next = realloc(out->p, cap);
    if (!next)
        return 0;
    out->p = next;
    out->cap = cap;
    return 1;
}

static int kiln_gz_run(zng_stream *z, const char *data, size_t len, int flush, kiln_gz_out *out) {
    z->next_in = (const uint8_t *)data;
    z->avail_in = (uint32_t)len;
    if (!kiln_gz_grow(out, zng_deflateBound(z, (unsigned long)len) + 64))
        return 0;
    for (;;) {
        z->next_out = (uint8_t *)out->p + out->len;
        z->avail_out = (uint32_t)(out->cap - out->len);
        int rc = zng_deflate(z, flush);
        out->len = out->cap - z->avail_out;
        if (rc == Z_STREAM_END)
            return 1;
        if (rc != Z_OK && rc != Z_BUF_ERROR)
            return 0;
        if (z->avail_in == 0 && z->avail_out != 0)
            return 1;
        if (!kiln_gz_grow(out, out->cap * 2))
            return 0;
    }
}

static const char *kiln_gz_result(kiln_gz_out *out) {
    char *str = sp_str_alloc(out->len);
    if (out->len && out->p)
        memcpy(str, out->p, out->len);
    free(out->p);
    return str;
}

#define KILN_GZIP_POOL 4

static pthread_mutex_t kiln_gz_lock = PTHREAD_MUTEX_INITIALIZER;
static zng_stream *kiln_gz_idle[10][KILN_GZIP_POOL];
static int kiln_gz_idle_count[10];

static zng_stream *kiln_gz_take(sp_int level) {
    int index = kiln_gz_level(level);
    zng_stream *z = NULL;
    pthread_mutex_lock(&kiln_gz_lock);
    if (kiln_gz_idle_count[index] > 0)
        z = kiln_gz_idle[index][--kiln_gz_idle_count[index]];
    pthread_mutex_unlock(&kiln_gz_lock);
    if (z && zng_deflateReset(z) == Z_OK)
        return z;
    if (z) {
        zng_deflateEnd(z);
        free(z);
    }
    return kiln_gz_new(level);
}

static void kiln_gz_give(sp_int level, zng_stream *z) {
    int index = kiln_gz_level(level);
    pthread_mutex_lock(&kiln_gz_lock);
    if (kiln_gz_idle_count[index] < KILN_GZIP_POOL) {
        kiln_gz_idle[index][kiln_gz_idle_count[index]++] = z;
        z = NULL;
    }
    pthread_mutex_unlock(&kiln_gz_lock);
    if (z) {
        zng_deflateEnd(z);
        free(z);
    }
}

#define KILN_GZIP_SCRATCH_MAX ((size_t)1 << 20)

static __thread char *kiln_gz_scratch;
static __thread size_t kiln_gz_scratch_cap;

static char *kiln_gz_room(size_t want) {
    if (want <= kiln_gz_scratch_cap)
        return kiln_gz_scratch;
    char *next = realloc(kiln_gz_scratch, want);
    if (!next)
        return NULL;
    kiln_gz_scratch = next;
    kiln_gz_scratch_cap = want;
    return next;
}

static void kiln_gz_trim(void) {
    if (kiln_gz_scratch_cap <= KILN_GZIP_SCRATCH_MAX)
        return;
    free(kiln_gz_scratch);
    kiln_gz_scratch = NULL;
    kiln_gz_scratch_cap = 0;
}

const char *kiln_gz_once(const char *src, sp_int level) {
    SP_GC_ROOT_STR(src);
    size_t len = src ? sp_str_byte_len(src) : 0;
    zng_stream *z = kiln_gz_take(level);
    if (!z)
        sp_raise_cls(KILN_GZIP_ERROR, "cannot start gzip");
    size_t bound = (size_t)zng_deflateBound(z, (unsigned long)len);
    char *room = kiln_gz_room(bound);
    if (!room) {
        kiln_gz_give(level, z);
        sp_raise_cls(KILN_GZIP_ERROR, "out of memory");
    }
    z->next_in = (const uint8_t *)(src ? src : "");
    z->avail_in = (uint32_t)len;
    z->next_out = (uint8_t *)room;
    z->avail_out = (uint32_t)bound;
    int rc = zng_deflate(z, Z_FINISH);
    size_t produced = bound - z->avail_out;
    kiln_gz_give(level, z);
    if (rc != Z_STREAM_END) {
        kiln_gz_trim();
        sp_raise_cls(KILN_GZIP_ERROR, "gzip failed");
    }
    char *str = sp_str_alloc(produced);
    if (produced)
        memcpy(str, room, produced);
    kiln_gz_trim();
    return str;
}

static int kiln_gz_flush(sp_int mode) {
    if (mode == 2)
        return Z_FINISH;
    if (mode == 1)
        return Z_SYNC_FLUSH;
    return Z_NO_FLUSH;
}

sp_int kiln_gz_open(sp_int level) {
    return (sp_int)(intptr_t)kiln_gz_new(level);
}

const char *kiln_gz_push(sp_int handle, const char *src, sp_int mode) {
    SP_GC_ROOT_STR(src);
    zng_stream *z = (zng_stream *)(intptr_t)handle;
    if (!z)
        sp_raise_cls(KILN_GZIP_ERROR, "gzip stream is closed");
    int flush = kiln_gz_flush(mode);
    size_t len = src ? sp_str_byte_len(src) : 0;
    kiln_gz_out out = {NULL, 0, 0};
    if (!kiln_gz_run(z, src ? src : "", len, flush, &out)) {
        free(out.p);
        sp_raise_cls(KILN_GZIP_ERROR, "gzip failed");
    }
    return kiln_gz_result(&out);
}

sp_int kiln_gz_close(sp_int handle) {
    zng_stream *z = (zng_stream *)(intptr_t)handle;
    if (!z)
        return 0;
    zng_deflateEnd(z);
    free(z);
    return 1;
}
