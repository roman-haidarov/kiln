#include <math.h>
#include <stdio.h>
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

#define KILN_JSON_ERROR     "Kiln::JsonError"
#define KILN_JSON_GEN_ERROR "Kiln::JsonGenerateError"

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
    switch (yyjson_get_type(val)) {
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
        if (depth >= jc->depth_limit) {
            jc->failed = 1;
            return sp_box_nil();
        }
        return kiln_json_array(jc, val, depth);
    case YYJSON_TYPE_OBJ:
        if (depth >= jc->depth_limit) {
            jc->failed = 1;
            return sp_box_nil();
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

typedef struct {
    char *p;
    size_t len;
    size_t cap;
} kiln_out;

typedef struct {
    kiln_out out;
    const char *error;
} kiln_gen;

static int kiln_reserve(kiln_gen *g, size_t extra) {
    if (g->out.p && g->out.len + extra <= g->out.cap)
        return 1;
    size_t cap = g->out.cap ? g->out.cap : 256;
    while (cap < g->out.len + extra)
        cap *= 2;
    char *next = realloc(g->out.p, cap);
    if (!next) {
        g->error = "out of memory";
        return 0;
    }
    g->out.p = next;
    g->out.cap = cap;
    return 1;
}

static int kiln_put(kiln_gen *g, const char *s, size_t n) {
    if (n == 0)
        return 1;
    if (!kiln_reserve(g, n))
        return 0;
    memcpy(g->out.p + g->out.len, s, n);
    g->out.len += n;
    return 1;
}

static int kiln_putc(kiln_gen *g, char c) {
    if (g->out.len < g->out.cap) {
        g->out.p[g->out.len++] = c;
        return 1;
    }
    return kiln_put(g, &c, 1);
}

static size_t kiln_utf8_seq(const unsigned char *s, size_t left) {
    unsigned char c = s[0];
    if (c >= 0xC2 && c <= 0xDF)
        return left >= 2 && (s[1] & 0xC0) == 0x80 ? 2 : 0;
    if (c >= 0xE0 && c <= 0xEF) {
        if (left < 3 || (s[1] & 0xC0) != 0x80 || (s[2] & 0xC0) != 0x80)
            return 0;
        if (c == 0xE0 && s[1] < 0xA0)
            return 0;
        if (c == 0xED && s[1] >= 0xA0)
            return 0;
        return 3;
    }
    if (c >= 0xF0 && c <= 0xF4) {
        if (left < 4 || (s[1] & 0xC0) != 0x80 || (s[2] & 0xC0) != 0x80 || (s[3] & 0xC0) != 0x80)
            return 0;
        if (c == 0xF0 && s[1] < 0x90)
            return 0;
        if (c == 0xF4 && s[1] >= 0x90)
            return 0;
        return 4;
    }
    return 0;
}

static int kiln_put_str(kiln_gen *g, const char *src, size_t len) {
    static const char hex[] = "0123456789abcdef";
    const unsigned char *s = (const unsigned char *)src;
    if (!kiln_reserve(g, len + 2))
        return 0;
    g->out.p[g->out.len++] = '"';
    size_t i = 0;
    while (i < len) {
        size_t run = i;
        while (run < len && s[run] >= 0x20 && s[run] < 0x80 && s[run] != '"' && s[run] != '\\')
            run++;
        if (run > i && !kiln_put(g, src + i, run - i))
            return 0;
        i = run;
        if (i >= len)
            break;
        unsigned char c = s[i];
        if (c >= 0x80) {
            size_t n = kiln_utf8_seq(s + i, len - i);
            if (!n) {
                g->error = "invalid UTF-8 in string";
                return 0;
            }
            if (!kiln_put(g, src + i, n))
                return 0;
            i += n;
            continue;
        }
        char esc[6] = {'\\', 0, 0, 0, 0, 0};
        size_t n = 2;
        switch (c) {
        case '"':
            esc[1] = '"';
            break;
        case '\\':
            esc[1] = '\\';
            break;
        case '\n':
            esc[1] = 'n';
            break;
        case '\r':
            esc[1] = 'r';
            break;
        case '\t':
            esc[1] = 't';
            break;
        case '\b':
            esc[1] = 'b';
            break;
        case '\f':
            esc[1] = 'f';
            break;
        default:
            esc[1] = 'u';
            esc[2] = '0';
            esc[3] = '0';
            esc[4] = hex[c >> 4];
            esc[5] = hex[c & 15];
            n = 6;
        }
        if (!kiln_put(g, esc, n))
            return 0;
        i++;
    }
    return kiln_putc(g, '"');
}

static int kiln_put_num(kiln_gen *g, yyjson_subtype sub, int64_t i, double f) {
    yyjson_val num;
    num.tag = (uint64_t)YYJSON_TYPE_NUM | (uint64_t)sub;
    if (sub == YYJSON_SUBTYPE_REAL)
        num.uni.f64 = f;
    else
        num.uni.i64 = i;
    if (!kiln_reserve(g, 48))
        return 0;
    char *end = yyjson_write_number(&num, g->out.p + g->out.len);
    if (!end) {
        g->error = "number not representable in JSON";
        return 0;
    }
    g->out.len = (size_t)(end - g->out.p);
    return 1;
}

static int kiln_put_sym(kiln_gen *g, sp_RbVal v) {
    const char *name = sp_sym_name_fn ? sp_sym_name_fn((sp_sym)v.v.i) : "";
    return kiln_put_str(g, name, strlen(name));
}

static int kiln_strbuf(sp_RbVal v) {
    return v.tag == SP_TAG_OBJ && v.cls_id == SP_BUILTIN_STRBUF && v.v.p;
}

static int kiln_put_strbuf(kiln_gen *g, sp_RbVal v) {
    const sp_String *str = (const sp_String *)v.v.p;
    return kiln_put_str(g, str->data ? str->data : "", str->data ? (size_t)str->len : 0);
}

static int kiln_put_key(kiln_gen *g, sp_RbVal k) {
    if (kiln_strbuf(k))
        return kiln_put_strbuf(g, k);
    switch (k.tag) {
    case SP_TAG_STR:
        return kiln_put_str(g, k.v.s, sp_str_byte_len(k.v.s));
    case SP_TAG_SYM:
        return kiln_put_sym(g, k);
    case SP_TAG_INT: {
        char digits[24];
        int n = snprintf(digits, sizeof digits, "%lld", (long long)k.v.i);
        return kiln_put_str(g, digits, (size_t)n);
    }
    case SP_TAG_BIGINT: {
        const char *digits = sp_bigint_to_s((sp_Bigint *)k.v.p);
        return kiln_put_str(g, digits, sp_str_byte_len(digits));
    }
    default:
        g->error = "unsupported Hash key type";
        return 0;
    }
}

static int kiln_gen_value(kiln_gen *g, sp_RbVal v, int depth) {
    switch (v.tag) {
    case SP_TAG_NIL:
        return kiln_put(g, "null", 4);
    case SP_TAG_BOOL:
        return v.v.b ? kiln_put(g, "true", 4) : kiln_put(g, "false", 5);
    case SP_TAG_INT:
        return kiln_put_num(g, YYJSON_SUBTYPE_SINT, (int64_t)v.v.i, 0.0);
    case SP_TAG_FLT:
        if (isnan(v.v.f) || isinf(v.v.f)) {
            g->error = "NaN and Infinity are not allowed in JSON";
            return 0;
        }
        return kiln_put_num(g, YYJSON_SUBTYPE_REAL, 0, v.v.f);
    case SP_TAG_BIGINT: {
        const char *digits = sp_bigint_to_s((sp_Bigint *)v.v.p);
        return kiln_put(g, digits, sp_str_byte_len(digits));
    }
    case SP_TAG_STR:
        return kiln_put_str(g, v.v.s, sp_str_byte_len(v.v.s));
    case SP_TAG_SYM:
        return kiln_put_sym(g, v);
    case SP_TAG_OBJ:
        break;
    default:
        g->error = "unsupported value type";
        return 0;
    }
    if (kiln_strbuf(v))
        return kiln_put_strbuf(g, v);
    int kind = sp_json_kind_fn ? sp_json_kind_fn(v) : 0;
    if (kind != 1 && kind != 2) {
        g->error = "unsupported object type (convert it to a Hash first)";
        return 0;
    }
    if (depth >= KILN_GEN_MAX_NESTING) {
        g->error = "nesting too deep (circular reference?)";
        return 0;
    }
    sp_int n = sp_json_len_fn(v);
    if (kind == 1) {
        if (!kiln_putc(g, '['))
            return 0;
        for (sp_int i = 0; i < n; i++) {
            if (i && !kiln_putc(g, ','))
                return 0;
            if (!kiln_gen_value(g, sp_json_aref_fn(v, i), depth + 1))
                return 0;
        }
        return kiln_putc(g, ']');
    }
    if (!kiln_putc(g, '{'))
        return 0;
    for (sp_int i = 0; i < n; i++) {
        sp_RbVal k;
        sp_RbVal val;
        sp_json_hpair_fn(v, i, &k, &val);
        if (i && !kiln_putc(g, ','))
            return 0;
        if (!kiln_put_key(g, k) || !kiln_putc(g, ':') || !kiln_gen_value(g, val, depth + 1))
            return 0;
    }
    return kiln_putc(g, '}');
}

const char *kiln_json_generate(sp_RbVal v) {
    SP_GC_ROOT_RBVAL(v);
    kiln_gen g = {{NULL, 0, 0}, NULL};
    if (!kiln_gen_value(&g, v, 0)) {
        const char *msg = g.error ? g.error : "cannot generate JSON";
        free(g.out.p);
        kiln_raise(KILN_JSON_GEN_ERROR, kiln_gc_str(msg, strlen(msg)));
    }
    char *out = sp_str_alloc(g.out.len);
    if (g.out.len)
        memcpy(out, g.out.p, g.out.len);
    free(g.out.p);
    return out;
}
