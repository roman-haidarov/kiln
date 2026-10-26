#ifndef KILN_CACHE_H
#define KILN_CACHE_H

#include <stdint.h>

#define KILN_CACHE_MAX_KEY     65536L
#define KILN_CACHE_MAX_VALUE   (1L << 30)
#define KILN_CACHE_MAX_ENTRIES (1L << 28)
#define KILN_CACHE_STATS       7
#define KILN_CACHE_BUSY        (-3)

long kiln_cache_open(long handle);
long kiln_cache_stats_read(long handle);
long kiln_cache_stat(long index);
long kiln_cache_new(long shards, long max_entries, long max_bytes, long max_value);
long kiln_cache_set(
    long handle, const char *key, long klen, const char *val, long vlen, long ttl_ms);
const char *kiln_cache_get(long handle, const char *key, long klen);
long kiln_cache_set_try(
    long handle, const char *key, long klen, const char *val, long vlen, long ttl_ms);
const char *kiln_cache_get_try(long handle, const char *key, long klen);
long kiln_cache_delete_try(long handle, const char *key, long klen);
long kiln_cache_found(void);
long kiln_cache_delete(long handle, const char *key, long klen);
long kiln_cache_sweep(long handle, long budget);
long kiln_cache_clear(long handle);
long kiln_cache_stats(long handle, int64_t *out, long cap);
long kiln_cache_free(long handle);

#endif
