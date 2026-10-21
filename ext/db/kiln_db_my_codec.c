#include "kiln_db.h"

#include <mysql.h>
#include <string.h>

int kiln_db_my_bind_set(void *bind, void *buffer, unsigned long cap, unsigned long *length,
    char *is_null, char *error, int type) {
    MYSQL_BIND *slot = bind;
    if (!slot) {
        return KILN_DB_ERR;
    }
    memset(slot, 0, sizeof *slot);
    slot->buffer = buffer;
    slot->buffer_length = cap;
    slot->length = length;
    slot->is_null = is_null;
    slot->error = error;
    slot->buffer_type = (enum enum_field_types)type;
    return KILN_DB_OK;
}

int kiln_db_my_bind_read(const void *bind, int *is_null, const void **ptr, uint32_t *len) {
    const MYSQL_BIND *slot = bind;
    unsigned long n;
    if (!slot || !is_null || !ptr || !len) {
        return KILN_DB_ERR;
    }
    if (slot->is_null && *slot->is_null) {
        *is_null = 1;
        *ptr = "";
        *len = 0;
        return KILN_DB_OK;
    }
    n = slot->length ? *slot->length : 0;
    if (n > UINT32_MAX) {
        return KILN_DB_CAPACITY;
    }
    *is_null = 0;
    *ptr = slot->buffer ? slot->buffer : "";
    *len = (uint32_t)n;
    return KILN_DB_OK;
}
