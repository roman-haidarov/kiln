#ifndef KILN_DB_H
#define KILN_DB_H

#if !defined(_POSIX_C_SOURCE) && !defined(__APPLE__)
#define _POSIX_C_SOURCE 200809L
#endif

#include <pthread.h>
#include <stddef.h>
#include <stdint.h>

#ifdef SP_THREADS
extern __thread int sp_ffi_bin_len;
#else
extern int sp_ffi_bin_len;
#endif

#define KILN_DB_OK          0
#define KILN_DB_ERR         1
#define KILN_DB_STALE       2
#define KILN_DB_OWNERSHIP   3
#define KILN_DB_CAPACITY    4
#define KILN_DB_TIMEOUT     5
#define KILN_DB_UNSUPPORTED 6
#define KILN_DB_CONFIG      7
#define KILN_DB_CONN        8
#define KILN_DB_UNIQUE      9
#define KILN_DB_FK          10
#define KILN_DB_NOTNULL     11
#define KILN_DB_CHECK       12
#define KILN_DB_DEADLOCK    13
#define KILN_DB_SERIAL      14
#define KILN_DB_NOTFOUND    15
#define KILN_DB_BUSY        16
#define KILN_DB_LOCKWAIT    17

#define KILN_DB_T_TEXT    0
#define KILN_DB_T_INT     1
#define KILN_DB_T_FLOAT   2
#define KILN_DB_T_DECIMAL 3
#define KILN_DB_T_BOOL    4
#define KILN_DB_T_BINARY  5
#define KILN_DB_T_UINT    6

#define KILN_DB_MAX_PARAMS 65535
#define KILN_DB_MAX_COLS   4096
#define KILN_DB_UUID_BYTES 16

#define KILN_DB_HOSTADDR_MAX 8
#define KILN_DB_HOSTADDR_CAP 512

#define KILN_DB_STEP_DONE 0
#define KILN_DB_STEP_WAIT 1
#define KILN_DB_STEP_ERR  2

#define KILN_DB_READY_READ    1
#define KILN_DB_READY_WRITE   2
#define KILN_DB_READY_BOTH    3
#define KILN_DB_READY_TIMEOUT 4

#define KILN_DB_KIND_PG 1
#define KILN_DB_KIND_MY 2

#define KILN_DB_OP_CONNECT        1
#define KILN_DB_OP_EXEC           2
#define KILN_DB_OP_DRAIN          3
#define KILN_DB_OP_CANCEL         4
#define KILN_DB_OP_CLOSE          5
#define KILN_DB_OP_BEGIN          6
#define KILN_DB_OP_COMMIT         7
#define KILN_DB_OP_ROLLBACK       8
#define KILN_DB_OP_SAVEPOINT      9
#define KILN_DB_OP_RELEASE        10
#define KILN_DB_OP_ROLLBACK_TO    11
#define KILN_DB_OP_COPY_START     12
#define KILN_DB_OP_COPY_DATA      13
#define KILN_DB_OP_COPY_END       14
#define KILN_DB_OP_PIPELINE_SYNC  15
#define KILN_DB_OP_PREPARE        16
#define KILN_DB_OP_PIPELINE_ENTER 17
#define KILN_DB_OP_PIPELINE_EXIT  18
#define KILN_DB_OP_PIPELINE_QUERY 19
#define KILN_DB_OP_PIPELINE_TAKE  20

#define KILN_DB_SSL_VERIFY_FULL 1
#define KILN_DB_SSL_DISABLE     2

#define KILN_DB_ISO_READ_COMMITTED  1
#define KILN_DB_ISO_REPEATABLE_READ 2
#define KILN_DB_ISO_SERIALIZABLE    3

#define KILN_DB_CAP_RETURNING        (1ull << 0)
#define KILN_DB_CAP_PIPELINE         (1ull << 1)
#define KILN_DB_CAP_COPY_BINARY      (1ull << 2)
#define KILN_DB_CAP_ARRAY_PARAMS     (1ull << 3)
#define KILN_DB_CAP_ARRAY_BINDING    (1ull << 4)
#define KILN_DB_CAP_CHUNKED_ROWS     (1ull << 5)
#define KILN_DB_CAP_LATERAL_JSON     (1ull << 6)
#define KILN_DB_CAP_NOTIFY           (1ull << 7)
#define KILN_DB_CAP_STMT_TIMEOUT_ALL (1ull << 8)

#define KILN_DB_GSTR_INLINE 12
#define KILN_DB_GSTR_CELL   16

#define KILN_DB_COL_I64  1
#define KILN_DB_COL_F64  2
#define KILN_DB_COL_BOOL 3
#define KILN_DB_COL_STR  4
#define KILN_DB_COL_DICT 5

#define KILN_DB_SLOT_FREE    0
#define KILN_DB_SLOT_LIVE    1
#define KILN_DB_SLOT_RETIRED 2

#define KILN_DB_CONFIG_VALUE_COUNT 8

typedef struct kiln_db_limits {
    uint32_t max_live_slots;
    uint32_t block_rows;
    uint32_t max_error_bytes;
    uint32_t max_payload_bytes;
    uint32_t max_resolver_queue;
    uint32_t max_pipeline_inflight;
    uint32_t max_dirty_groups;
    uint32_t copy_min_rows;
} kiln_db_limits;

typedef struct kiln_db_gstr {
    uint8_t bytes[KILN_DB_GSTR_CELL];
} kiln_db_gstr;

typedef struct kiln_db_block kiln_db_block;
typedef struct kiln_db_conn kiln_db_conn;

static inline uint32_t kiln_db_null_words(uint32_t rows) {
    return (rows / 64u) + (rows % 64u != 0);
}

struct kiln_db_block {
    uint32_t generation;
    uint32_t arena_id;
    uint64_t scope;
    uint64_t thread_id;
    uint32_t rows;
    uint32_t capacity;
    uint32_t ncols;
    uint8_t *kinds;
    uint8_t **data;
    uint64_t **nulls;
    uint8_t **heap;
    uint32_t *heap_len;
    uint32_t *heap_cap;
    uint32_t *dict_count;
    uint8_t *dict_width;
    char **dict_bytes;
    uint32_t *dict_lens;
    uint32_t *dict_cap;
    int tentative;
    kiln_db_block *next;
};

struct kiln_db_conn {
    uint32_t slot;
    uint32_t generation;
    uint64_t scope;
    uint64_t thread_id;
    int kind;
    int state;
    int tx_state;
    int op;
    int fd;
    int wait_kind;
    int err;
    int vendor_errno;
    int rows_affected;
    int insecure_ok;
    int ssl_mode;
    int port;
    int isolation;
    int read_only;
    int in_pipeline;
    int savepoint_depth;
    int64_t deadline_ms;
    uint32_t op_id;
    uint32_t conn_generation;
    uint32_t fd_generation;
    char sqlstate[6];
    char *error;
    uint32_t error_cap;
    char *host;
    char *hostaddr;
    char *user;
    char *pass;
    char *database;
    char *ca_path;
    char *tls_name;
    char *sql;
    size_t sql_len;
    void *native;
    int prepared;
    int stmt_cache;
    void *cancel;
    void *res;
    kiln_db_block *blocks;
    int broken;
    int copy_open;
    int fetch_done;
    int setup_phase;
    int ready_hint;
    unsigned long mysql_thread;
    char server_identity[64];
    int cancel_armed;
    int result_format;
    int64_t wait_ms;
    int active_op;
    pthread_t owner;
};

int kiln_db_configure(const kiln_db_limits *limits);
const kiln_db_limits *kiln_db_limits_get(void);

int kiln_db_load_kind(int kind);
long kiln_db_client_version(int kind);
const char *kiln_db_load_error(void);
void kiln_db_set_load_error(const char *text);
int kiln_db_pg_load(void);
int kiln_db_my_load(void);
long kiln_db_pg_client_version(void);
long kiln_db_my_client_version(void);
int kiln_db_pg_bind_str(
    kiln_db_conn *conn, uint32_t index, const char *data, long n, int is_null, int format);
int kiln_db_my_bind_str(
    kiln_db_conn *conn, uint32_t index, const char *data, long n, int is_null, int format);
int kiln_db_pg_result_types(kiln_db_conn *conn, int64_t *out, int n);
int kiln_db_my_result_types(kiln_db_conn *conn, int64_t *out, int n);
const char *kiln_db_pg_result_row(kiln_db_conn *conn, uint32_t row, int64_t *lens, int n);
const char *kiln_db_my_result_row(kiln_db_conn *conn, uint32_t row, int64_t *lens, int n);
const char *kiln_db_pg_result_rows(kiln_db_conn *conn, uint32_t first, uint32_t max_rows,
    size_t max_bytes, int64_t *lens, int lens_cap, int64_t *meta);
const char *kiln_db_my_result_rows(kiln_db_conn *conn, uint32_t first, uint32_t max_rows,
    size_t max_bytes, int64_t *lens, int lens_cap, int64_t *meta);
int kiln_db_pg_result_meta(kiln_db_conn *conn, int64_t *out, int n);
int kiln_db_my_result_meta(kiln_db_conn *conn, int64_t *out, int n);
const char *kiln_db_pg_result_bytes(
    kiln_db_conn *conn, uint32_t row, uint32_t col, int64_t *meta, int meta_n);
const char *kiln_db_my_result_bytes(
    kiln_db_conn *conn, uint32_t row, uint32_t col, int64_t *meta, int meta_n);
uint64_t kiln_db_caps(int kind);

uint64_t kiln_db_conn_create(int kind, uint64_t scope, uint64_t thread_id, int64_t *err);
int kiln_db_conn_set(uint64_t handle, uint64_t scope, uint64_t thread_id, const char *host,
    size_t host_len, int port, const char *user, size_t user_len, const char *pass, size_t pass_len,
    const char *database, size_t database_len, int ssl_mode, const char *ca, size_t ca_len,
    int allow_insecure, const char *tls_name, size_t tls_name_len);
int kiln_db_set_sql(
    uint64_t handle, uint64_t scope, uint64_t thread_id, const char *sql, size_t sql_len);
int kiln_db_step(uint64_t handle, uint64_t scope, uint64_t thread_id, int op, int ready_bits,
    int64_t deadline_ms, int64_t *out, int out_n);
int kiln_db_take_error(uint64_t handle, uint64_t scope, uint64_t thread_id, char *buf, size_t cap,
    int *vendor, char sqlstate[6]);
const char *kiln_db_error_text(uint64_t handle, uint64_t scope, uint64_t thread_id);

uint64_t kiln_db_arena_open(uint64_t scope, uint64_t thread_id, int *err);
int kiln_db_arena_close(uint64_t handle, uint64_t scope, uint64_t thread_id);
uint64_t kiln_db_block_new(uint64_t arena, uint64_t scope, uint64_t thread_id, uint32_t rows,
    uint32_t cols, const uint8_t *kinds, int *err);
kiln_db_block *kiln_db_block_get(uint64_t handle, uint64_t scope, uint64_t thread_id, int *err);
int kiln_db_block_set_i64(kiln_db_block *b, uint32_t col, uint32_t row, int is_null, int64_t value);
int kiln_db_block_set_f64(kiln_db_block *b, uint32_t col, uint32_t row, int is_null, double value);
int kiln_db_block_set_bool(kiln_db_block *b, uint32_t col, uint32_t row, int is_null, int value);
int kiln_db_block_set_str(
    kiln_db_block *b, uint32_t col, uint32_t row, int is_null, const void *bytes, uint32_t len);
int kiln_db_block_set_dict(
    kiln_db_block *b, uint32_t col, uint32_t row, int is_null, const void *bytes, uint32_t len);
int kiln_db_block_rows(kiln_db_block *b, uint32_t rows);

int kiln_db_copy_i64(
    uint64_t handle, uint64_t scope, uint64_t thread_id, uint32_t col, int64_t *dst, uint32_t n);
int kiln_db_copy_f64(
    uint64_t handle, uint64_t scope, uint64_t thread_id, uint32_t col, double *dst, uint32_t n);
int kiln_db_copy_nulls(uint64_t handle, uint64_t scope, uint64_t thread_id, uint32_t col,
    int64_t *dst, uint32_t words);
int kiln_db_copy_strs(uint64_t handle, uint64_t scope, uint64_t thread_id, uint32_t col, char *dst,
    size_t dst_cap, size_t *nbytes, int64_t *offsets, uint32_t n);

int kiln_db_gstr_put(uint8_t cell[KILN_DB_GSTR_CELL], uint8_t **heap, uint32_t *heap_len,
    uint32_t *heap_cap, const void *data, uint32_t len);
int kiln_db_gstr_read(const uint8_t cell[KILN_DB_GSTR_CELL], const uint8_t *heap, uint32_t heap_len,
    const uint8_t **out, uint32_t *out_len);

int kiln_db_bitset_and(uint64_t *dst, const uint64_t *a, const uint64_t *b, uint32_t words);
int kiln_db_bitset_or(uint64_t *dst, const uint64_t *a, const uint64_t *b, uint32_t words);
int kiln_db_bitset_not(uint64_t *dst, const uint64_t *a, uint32_t bits, uint32_t words);

void kiln_db_metrics(int64_t *out, int n);
void kiln_db_metrics_reset_test(void);

int kiln_db_idset_new(int kind, uint64_t *out_handle);
int kiln_db_idset_add_u64(uint64_t handle, uint64_t value);
int kiln_db_idset_has_u64(uint64_t handle, uint64_t value);
int kiln_db_idset_add_uuid(uint64_t handle, const uint8_t key[KILN_DB_UUID_BYTES]);
int kiln_db_idset_has_uuid(uint64_t handle, const uint8_t key[KILN_DB_UUID_BYTES]);
int kiln_db_idset_free(uint64_t handle);

typedef int (*kiln_db_step_fn)(kiln_db_conn *conn, int ready_bits, int64_t deadline_ms);
typedef void (*kiln_db_release_fn)(kiln_db_conn *conn);
void kiln_db_driver_register(int kind, kiln_db_step_fn step, kiln_db_release_fn release);

kiln_db_conn *kiln_db_conn_get(uint64_t handle, uint64_t scope, uint64_t thread_id, int *err);
int kiln_db_fail(
    kiln_db_conn *conn, int code, int vendor, const char *sqlstate, const char *message);
void kiln_db_step_out(
    int64_t *out, int out_n, int status, int fd, int ready, int64_t timeout_ms, int err);
int kiln_db_is_ready(void);
int kiln_db_resolver_boot(uint32_t queue);
int kiln_db_resolver_submit(
    const char *host, size_t host_len, int *wait_fd, char *addr, size_t addr_cap, int *done);
int kiln_db_resolver_take(int slot, char *addr, size_t addr_cap);
int kiln_db_resolver_cancel(int slot);
int kiln_db_dns_submit(const char *host, long n, int64_t *out, int len);
const char *kiln_db_dns_take(int id, int64_t *state, int n);
int kiln_db_conn_set_hostaddr(
    uint64_t handle, uint64_t scope, uint64_t thread_id, const char *addr, long n);
int kiln_db_configure_values(const int64_t *values, int n);
char *kiln_db_thread_room(size_t need);
int64_t kiln_db_now_ms(void);
int kiln_db_set_format(uint64_t handle, uint64_t scope, uint64_t thread_id, int format, int chunk);
int kiln_db_set_stmt_cache(uint64_t handle, uint64_t scope, uint64_t thread_id, int capacity);
int kiln_db_bind_str(uint64_t handle, uint64_t scope, uint64_t thread_id, uint32_t index,
    const char *data, long n, int is_null, int format);
int kiln_db_result_types(uint64_t handle, uint64_t scope, uint64_t thread_id, int64_t *out, int n);
const char *kiln_db_result_row(
    uint64_t handle, uint64_t scope, uint64_t thread_id, uint32_t row, int64_t *lens, int n);
const char *kiln_db_result_rows(uint64_t handle, uint64_t scope, uint64_t thread_id,
    int64_t first_row, int64_t max_rows, int64_t max_bytes, int64_t *lens, int lens_cap,
    int64_t *meta, int meta_n);
int kiln_db_conn_broken(uint64_t handle, uint64_t scope, uint64_t thread_id);
int64_t kiln_db_os_thread_token(void);
int kiln_db_result_meta(uint64_t handle, uint64_t scope, uint64_t thread_id, int64_t *out, int n);
const char *kiln_db_result_bytes(uint64_t handle, uint64_t scope, uint64_t thread_id, uint32_t row,
    uint32_t col, int64_t *meta, int meta_n);
int64_t kiln_db_peer_id(uint64_t handle, uint64_t scope, uint64_t thread_id);
int kiln_db_block_open(uint64_t scope, uint64_t thread_id, uint32_t rows, uint32_t cols,
    const int64_t *kinds, int n, int64_t *out, int out_n);
int kiln_db_block_close(uint64_t block, uint64_t arena, uint64_t scope, uint64_t thread_id);
int kiln_db_block_import(uint64_t conn, uint64_t block, uint64_t scope, uint64_t thread_id,
    uint32_t dest_row, int64_t *out, int out_n);
int kiln_db_copy_null_rows(
    uint64_t handle, uint64_t scope, uint64_t thread_id, uint32_t col, int64_t *dst, uint32_t n);
const char *kiln_db_block_text(uint64_t handle, uint64_t scope, uint64_t thread_id, uint32_t col,
    int64_t *offs, int offs_n, int64_t *lens, int lens_n, int64_t *meta, int meta_n);

#define KILN_DB_NUM_ADD 1
#define KILN_DB_NUM_SUB 2
#define KILN_DB_NUM_MUL 3
#define KILN_DB_NUM_DIV 4
#define KILN_DB_NUM_MOD 5
#define KILN_DB_NUM_NEG 6

int kiln_db_i64_parse(const char *text, int64_t *out, int n);
int kiln_db_u64_parse(const char *text, int64_t *out, int n);
int kiln_db_i64_apply(int op, int64_t ah, int64_t al, int64_t bh, int64_t bl, int64_t *out, int n);
int kiln_db_u64_apply(int op, int64_t ah, int64_t al, int64_t bh, int64_t bl, int64_t *out, int n);
int kiln_db_i64_cmp_text(int64_t hi, int64_t lo, const char *text, int64_t *out, int n);
int kiln_db_u64_cmp_text(int64_t hi, int64_t lo, const char *text, int64_t *out, int n);
const char *kiln_db_i64_text(int64_t hi, int64_t lo);
const char *kiln_db_u64_text(int64_t hi, int64_t lo);

int kiln_db_pg_field(
    const char *value, int length, int is_null, int *out_null, const char **out, int *out_len);
int kiln_db_my_bind_set(void *bind, void *buffer, unsigned long cap, unsigned long *length,
    char *is_null, char *error, int type);
int kiln_db_my_bind_read(const void *bind, int *is_null, const void **ptr, uint32_t *len);

#define KILN_DB_SLOT_CONN  1
#define KILN_DB_SLOT_BLOCK 2
#define KILN_DB_SLOT_ARENA 3

#define KILN_DB_METRIC_N              11
#define KILN_DB_METRIC_INFLIGHT       0
#define KILN_DB_METRIC_WATCHERS       1
#define KILN_DB_METRIC_CANCEL         2
#define KILN_DB_METRIC_LEASE          3
#define KILN_DB_METRIC_UNSAFE_CHECKIN 4
#define KILN_DB_METRIC_BLOCKING       5
#define KILN_DB_METRIC_STALE          6
#define KILN_DB_METRIC_PARTIAL        7
#define KILN_DB_METRIC_MY_RETURNING   8
#define KILN_DB_METRIC_PREPARE        9
#define KILN_DB_METRIC_EXEC           10

uint64_t kiln_db_slot_put(int kind, void *ptr, uint64_t scope, uint64_t thread_id, int *err);
void *kiln_db_slot_use(uint64_t handle, int kind, uint64_t scope, uint64_t thread_id, int *err);
int kiln_db_slot_take(uint64_t handle, int kind, uint64_t scope, uint64_t thread_id, void **out);
int kiln_db_slot_pin(uint64_t handle, int kind, uint64_t scope, uint64_t thread_id);
int kiln_db_slot_unpin(uint64_t handle, int kind, uint64_t scope, uint64_t thread_id);
void *kiln_db_slot_acquire(uint64_t handle, int kind, uint64_t scope, uint64_t thread_id, int *err);
void kiln_db_slot_release(uint64_t handle, int kind);
int kiln_db_slot_take_conn_idle(uint64_t handle, uint64_t scope, uint64_t thread_id, void **out);
void kiln_db_metric_add(int id, int64_t delta);
void kiln_db_block_free(kiln_db_block *block);

#endif
