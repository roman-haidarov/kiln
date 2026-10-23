#include "kiln_db.h"

int kiln_db_pg_field(
    const char *value, int length, int is_null, int *out_null, const char **out, int *out_len) {
    if (!out_null || !out || !out_len) {
        return KILN_DB_ERR;
    }
    if (is_null) {
        *out_null = 1;
        *out = "";
        *out_len = 0;
        return KILN_DB_OK;
    }
    if (length < 0 || (!value && length > 0)) {
        return KILN_DB_ERR;
    }
    *out_null = 0;
    *out = value ? value : "";
    *out_len = length;
    return KILN_DB_OK;
}
