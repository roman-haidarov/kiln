#include <math.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "spinel/runtime.h"
#include "sp_string.h"
#include "yyjson/yyjson.h"

sp_Bigint *sp_bigint_new_str(const char *s, int base);

#if defined(__has_feature)
#if __has_feature(address_sanitizer)
#define KILN_ASAN 1
#endif
#endif
#if defined(__SANITIZE_ADDRESS__)
#define KILN_ASAN 1
#endif

#ifdef KILN_ASAN
typedef void (*kiln_raise_fn)(const char *, const char *);
static kiln_raise_fn volatile kiln_raise = (kiln_raise_fn)sp_raise_cls;
#define KILN_NORETURN
#else
#define kiln_raise    sp_raise_cls
#define KILN_NORETURN SP_NORETURN
#endif

#define KILN_JSON_ERROR     "Kiln::HTTP::JsonError"
#define KILN_JSON_GEN_ERROR "Kiln::HTTP::JsonGenerateError"

#define KILN_KEY_SLOTS 256
#define KILN_KEY_MAX   64

typedef struct {
    const char *str;
    uint32_t len;
    uint32_t hash;
} kiln_key_slot;

typedef struct {
    long depth_limit;
    int failed;
    kiln_key_slot *keys;
} kiln_jctx;

static const char *kiln_gc_str(const char *src, size_t len) {
    char *out = sp_str_alloc(len);
    if (len)
        memcpy(out, src, len);
    return out;
}

static KILN_NORETURN void kiln_json_fail(
    yyjson_doc *doc, const char *msg, size_t pos, int with_pos) {
    char buf[160];
    if (with_pos)
        snprintf(buf, sizeof buf, "%s at byte %zu", msg, pos);
    else
        snprintf(buf, sizeof buf, "%s", msg);
    if (doc)
        yyjson_doc_free(doc);
    kiln_raise(KILN_JSON_ERROR, kiln_gc_str(buf, strlen(buf)));
}

static sp_RbVal kiln_json_raw(yyjson_val *val) {
    const char *raw = yyjson_get_raw(val);
    size_t len = yyjson_get_len(val);
    if (memchr(raw, '.', len) || memchr(raw, 'e', len) || memchr(raw, 'E', len))
        return sp_box_float(strtod(raw, NULL));
    return sp_box_bigint(sp_bigint_new_str(raw, 10));
}

static sp_RbVal kiln_json_uint(uint64_t v) {
    if (v <= (uint64_t)INT64_MAX)
        return sp_box_i64((int64_t)v);
    char digits[24];
    snprintf(digits, sizeof digits, "%llu", (unsigned long long)v);
    return sp_box_bigint(sp_bigint_new_str(digits, 10));
}

static sp_RbVal kiln_json_value(kiln_jctx *jc, yyjson_val *val, long depth);

static const char *kiln_json_key(kiln_jctx *jc, const char *src, size_t len) {
    if (len > KILN_KEY_MAX)
        return kiln_gc_str(src, len);
    if (!jc->keys) {
        jc->keys = calloc(KILN_KEY_SLOTS, sizeof *jc->keys);
        if (!jc->keys)
            return kiln_gc_str(src, len);
    }
    uint32_t hash = 2166136261U;
    for (size_t i = 0; i < len; i++)
        hash = (hash ^ (unsigned char)src[i]) * 16777619U;
    kiln_key_slot *slot = &jc->keys[hash & (KILN_KEY_SLOTS - 1)];
    if (slot->str && slot->hash == hash && slot->len == len && memcmp(slot->str, src, len) == 0)
        return slot->str;
    const char *out = kiln_gc_str(src, len);
    slot->str = out;
    slot->len = (uint32_t)len;
    slot->hash = hash;
    return out;
}

static sp_RbVal kiln_json_array(kiln_jctx *jc, yyjson_val *val, long depth) {
    sp_RbVal box = sp_box_poly_array(sp_PolyArray_new());
    SP_GC_ROOT_RBVAL(box);
    yyjson_arr_iter it = yyjson_arr_iter_with(val);
    yyjson_val *item;
    while ((item = yyjson_arr_iter_next(&it))) {
        sp_RbVal v = kiln_json_value(jc, item, depth + 1);
        if (jc->failed)
            return box;
        sp_PolyArray_push((sp_PolyArray *)box.v.p, v);
    }
    return box;
}

static sp_RbVal kiln_json_object(kiln_jctx *jc, yyjson_val *val, long depth) {
    sp_RbVal box = sp_json_mk_hash_fn();
    SP_GC_ROOT_RBVAL(box);
    yyjson_obj_iter it = yyjson_obj_iter_with(val);
    yyjson_val *key;
    while ((key = yyjson_obj_iter_next(&it))) {
        const char *name = kiln_json_key(jc, yyjson_get_str(key), yyjson_get_len(key));
        SP_GC_ROOT_STR(name);
        sp_RbVal v = kiln_json_value(jc, yyjson_obj_iter_get_val(key), depth + 1);
        if (jc->failed)
            return box;
        sp_json_hash_set_fn(box, name, v);
    }
    return box;
}

static sp_RbVal kiln_json_value(kiln_jctx *jc, yyjson_val *val, long depth) {
    yyjson_type type = yyjson_get_type(val);
    switch (type) {
    case YYJSON_TYPE_NULL:
        return sp_box_nil();
    case YYJSON_TYPE_BOOL:
        return sp_box_bool(yyjson_get_bool(val));
    case YYJSON_TYPE_NUM:
        switch (yyjson_get_subtype(val)) {
        case YYJSON_SUBTYPE_SINT:
            return sp_box_i64(yyjson_get_sint(val));
        case YYJSON_SUBTYPE_UINT:
            return kiln_json_uint(yyjson_get_uint(val));
        default:
            return sp_box_float(yyjson_get_real(val));
        }
    case YYJSON_TYPE_RAW:
        return kiln_json_raw(val);
    case YYJSON_TYPE_STR:
        return sp_box_str(kiln_gc_str(yyjson_get_str(val), yyjson_get_len(val)));
    case YYJSON_TYPE_ARR:
    case YYJSON_TYPE_OBJ:
        if (depth >= jc->depth_limit) {
            jc->failed = 1;
            return sp_box_nil();
        }
        if (type == YYJSON_TYPE_ARR) {
            return kiln_json_array(jc, val, depth);
        }
        return kiln_json_object(jc, val, depth);
    default:
        jc->failed = 2;
        return sp_box_nil();
    }
}

sp_RbVal kiln_json_parse(const char *src, sp_int max_depth) {
    SP_GC_ROOT_STR(src);
    size_t len = src ? sp_str_byte_len(src) : 0;
    yyjson_read_err err;
    yyjson_doc *doc =
        yyjson_read_opts((char *)(src ? src : ""), len, YYJSON_READ_BIGNUM_AS_RAW, NULL, &err);
    if (!doc) {
        if (len == 0 || err.code == YYJSON_READ_ERROR_EMPTY_CONTENT)
            kiln_json_fail(NULL, "empty input", 0, 0);
        kiln_json_fail(NULL, err.msg ? err.msg : "invalid JSON", err.pos, 1);
    }
    kiln_jctx jc = {max_depth < 1 ? 1 : (long)max_depth, 0, NULL};
    sp_RbVal out = kiln_json_value(&jc, yyjson_doc_get_root(doc), 0);
    int failed = jc.failed;
    free(jc.keys);
    SP_GC_ROOT_RBVAL(out);
    if (failed == 1)
        kiln_json_fail(doc, "nesting too deep", 0, 0);
    if (failed)
        kiln_json_fail(doc, "unsupported JSON value", 0, 0);
    yyjson_doc_free(doc);
    return out;
}

#define KILN_GEN_MAX_NESTING 100

static int kiln_strbuf(sp_RbVal v) {
    return v.tag == SP_TAG_OBJ && v.cls_id == SP_BUILTIN_STRBUF && v.v.p;
}

static yyjson_mut_val *kiln_yy_key(yyjson_mut_doc *d, sp_RbVal k, const char **err) {
    if (kiln_strbuf(k)) {
        const sp_String *str = (const sp_String *)k.v.p;
        return yyjson_mut_strn(d, str->data ? str->data : "", str->data ? (size_t)str->len : 0);
    }
    switch (k.tag) {
    case SP_TAG_STR:
        return yyjson_mut_strn(d, k.v.s, sp_str_byte_len(k.v.s));
    case SP_TAG_SYM: {
        const char *name = sp_sym_name_fn ? sp_sym_name_fn((sp_sym)k.v.i) : "";
        return yyjson_mut_strn(d, name, strlen(name));
    }
    case SP_TAG_INT: {
        char digits[24];
        int n = snprintf(digits, sizeof digits, "%lld", (long long)k.v.i);
        return yyjson_mut_strncpy(d, digits, (size_t)n);
    }
    case SP_TAG_BIGINT: {
        const char *digits = sp_bigint_to_s((sp_Bigint *)k.v.p);
        return yyjson_mut_strncpy(d, digits, sp_str_byte_len(digits));
    }
    default:
        *err = "unsupported Hash key type";
        return NULL;
    }
}

static yyjson_mut_val *kiln_yy_value(yyjson_mut_doc *d, sp_RbVal v, int depth, const char **err) {
    switch (v.tag) {
    case SP_TAG_NIL:
        return yyjson_mut_null(d);
    case SP_TAG_BOOL:
        return yyjson_mut_bool(d, v.v.b);
    case SP_TAG_INT:
        return yyjson_mut_sint(d, (int64_t)v.v.i);
    case SP_TAG_FLT:
        if (isnan(v.v.f) || isinf(v.v.f)) {
            *err = "NaN and Infinity are not allowed in JSON";
            return NULL;
        }
        return yyjson_mut_real(d, v.v.f);
    case SP_TAG_BIGINT: {
        const char *digits = sp_bigint_to_s((sp_Bigint *)v.v.p);
        return yyjson_mut_rawncpy(d, digits, sp_str_byte_len(digits));
    }
    case SP_TAG_STR:
        return yyjson_mut_strn(d, v.v.s, sp_str_byte_len(v.v.s));
    case SP_TAG_SYM: {
        const char *name = sp_sym_name_fn ? sp_sym_name_fn((sp_sym)v.v.i) : "";
        return yyjson_mut_strn(d, name, strlen(name));
    }
    case SP_TAG_OBJ:
        break;
    default:
        *err = "unsupported value type";
        return NULL;
    }
    if (kiln_strbuf(v)) {
        const sp_String *str = (const sp_String *)v.v.p;
        return yyjson_mut_strn(d, str->data ? str->data : "", str->data ? (size_t)str->len : 0);
    }
    int kind = sp_json_kind_fn ? sp_json_kind_fn(v) : 0;
    if (kind != 1 && kind != 2) {
        *err = "unsupported object type (convert it to a Hash first)";
        return NULL;
    }
    if (depth >= KILN_GEN_MAX_NESTING) {
        *err = "nesting too deep (circular reference?)";
        return NULL;
    }
    sp_int n = sp_json_len_fn(v);
    if (kind == 1) {
        yyjson_mut_val *arr = yyjson_mut_arr(d);
        for (sp_int i = 0; i < n; i++) {
            yyjson_mut_val *item = kiln_yy_value(d, sp_json_aref_fn(v, i), depth + 1, err);
            if (!item || !yyjson_mut_arr_append(arr, item))
                return NULL;
        }
        return arr;
    }
    yyjson_mut_val *obj = yyjson_mut_obj(d);
    for (sp_int i = 0; i < n; i++) {
        sp_RbVal k;
        sp_RbVal val;
        sp_json_hpair_fn(v, i, &k, &val);
        yyjson_mut_val *key = kiln_yy_key(d, k, err);
        yyjson_mut_val *item = key ? kiln_yy_value(d, val, depth + 1, err) : NULL;
        if (!item || !yyjson_mut_obj_add(obj, key, item))
            return NULL;
    }
    return obj;
}

#define KILN_GEN_POOL_MIN ((size_t)16 << 10)
#define KILN_GEN_POOL_MAX ((size_t)1 << 20)

static __thread char *kiln_gen_pool;
static __thread size_t kiln_gen_pool_cap;
static __thread int kiln_gen_pool_busy;

static char *kiln_gen_write(sp_RbVal v, const yyjson_alc *alc, size_t *len, const char **err) {
    yyjson_mut_doc *d = yyjson_mut_doc_new(alc);
    if (!d)
        return NULL;
    yyjson_mut_val *root = kiln_yy_value(d, v, 0, err);
    char *text = NULL;
    if (root) {
        yyjson_write_err werr;
        yyjson_mut_doc_set_root(d, root);
        text = yyjson_mut_write_opts(d, 0, alc, len, &werr);
        if (!text && werr.code != YYJSON_WRITE_ERROR_MEMORY_ALLOCATION)
            *err = werr.code == YYJSON_WRITE_ERROR_INVALID_STRING ? "invalid UTF-8 in string"
                                                                  : werr.msg;
    }
    yyjson_mut_doc_free(d);
    return text;
}

static int kiln_gen_grow(size_t cap) {
    char *next = malloc(cap);
    if (!next)
        return 0;
    free(kiln_gen_pool);
    kiln_gen_pool = next;
    kiln_gen_pool_cap = cap;
    return 1;
}

const char *kiln_json_generate(sp_RbVal v) {
    SP_GC_ROOT_RBVAL(v);
    const char *err = NULL;
    size_t len = 0;
    char *text = NULL;
    if (!kiln_gen_pool_busy && (kiln_gen_pool || kiln_gen_grow(KILN_GEN_POOL_MIN))) {
        kiln_gen_pool_busy = 1;
        for (;;) {
            yyjson_alc alc;
            yyjson_alc_pool_init(&alc, kiln_gen_pool, kiln_gen_pool_cap);
            text = kiln_gen_write(v, &alc, &len, &err);
            if (text || err || kiln_gen_pool_cap >= KILN_GEN_POOL_MAX ||
                !kiln_gen_grow(kiln_gen_pool_cap * 4))
                break;
        }
        char *out = text ? sp_str_alloc(len) : NULL;
        if (out)
            memcpy(out, text, len);
        kiln_gen_pool_busy = 0;
        if (out)
            return out;
    }
    if (!err) {
        text = kiln_gen_write(v, NULL, &len, &err);
        if (text) {
            char *out = sp_str_alloc(len);
            memcpy(out, text, len);
            free(text);
            return out;
        }
    }
    const char *msg = err ? err : "out of memory";
    kiln_raise(KILN_JSON_GEN_ERROR, kiln_gc_str(msg, strlen(msg)));
    return "";
}
