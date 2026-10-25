#include <assert.h>
#include <stdio.h>
#include "../ext/kiln_uv.c"

__thread int sp_ffi_bin_len;

int main(void) {
    for (int state = 0; state < KUV_CONN_STATE_COUNT; state++) {
        for (int event = 0; event < KUV_CONN_EVENT_COUNT; event++) {
            kuv_conn_state next = kuv_conn_next((kuv_conn_state)state, (kuv_conn_event)event);
            assert(next >= (kuv_conn_state)state);
            assert(next < KUV_CONN_STATE_COUNT);
        }
        assert(kuv_conn_next((kuv_conn_state)state, KUV_CONN_CLOSE) == KUV_CONN_CLOSING);
    }
    assert(kuv_conn_next(KUV_CONN_OPEN, KUV_CONN_FINISH) == KUV_CONN_FLUSHING);
    assert(kuv_conn_next(KUV_CONN_FLUSHING, KUV_CONN_LINGER) == KUV_CONN_LINGERING);
    assert(kuv_conn_next(KUV_CONN_LINGERING, KUV_CONN_FINISH) == KUV_CONN_LINGERING);
    assert(kuv_conn_next(KUV_CONN_CLOSING, KUV_CONN_LINGER) == KUV_CONN_CLOSING);

    kuv_conn c = {0};
    assert(kuv_wants_read(&c));
    c.parse_state = KUV_PARSE_UPGRADE;
    assert(!kuv_wants_read(&c));
    kuv_release_upgrade(&c);
    assert(kuv_wants_read(&c));
    c.parse_state = KUV_PARSE_UPGRADE;
    kuv_stop_parsing(&c);
    kuv_release_upgrade(&c);
    assert(c.parse_state == KUV_PARSE_STOPPED);
    assert(!kuv_wants_read(&c));

    c.body_mode = KUV_BODY_LENGTH;
    c.body_state = KUV_BODY_READING;
    assert(kuv_wants_read(&c));
    kuv_body_pause(&c);
    assert(!kuv_wants_read(&c));
    kuv_body_resume(&c);
    assert(kuv_wants_read(&c));
    kuv_body_complete(&c);
    kuv_body_pause(&c);
    assert(c.body_state == KUV_BODY_DONE);
    assert(!kuv_wants_read(&c));

    c.body_state = KUV_BODY_FAILED;
    c.body_error = 400;
    kuv_body_complete(&c);
    kuv_body_resume(&c);
    assert(c.body_state == KUV_BODY_FAILED);
    assert(!kuv_wants_read(&c));
    c.state = KUV_CONN_LINGERING;
    assert(kuv_wants_read(&c));
    c.state = KUV_CONN_CLOSING;
    assert(!kuv_wants_read(&c));
    c.state = KUV_CONN_LINGERING;
    c.read_eof = 1;
    assert(!kuv_wants_read(&c));
    free(c.in);
    free(c.body);
    memset(&c, 0, sizeof(c));
    c.body_mode = KUV_BODY_LENGTH;
    c.body_state = KUV_BODY_READING;
    c.body_left = 3;
    c.in = strdup("abcNEXT");
    c.in_len = 7;
    kuv_body_feed(&c);
    assert(c.body_len == 3 && memcmp(c.body, "abc", 3) == 0);
    assert(c.body_left == 0 && c.in_len == 4 && memcmp(c.in, "NEXT", 4) == 0);
    kuv_body_complete(&c);
    assert(c.body_state == KUV_BODY_DONE);
    kuv_body_release(&c);
    assert(c.body_mode == KUV_BODY_NONE && c.body_state == KUV_BODY_IDLE);
    free(c.in);
    free(c.body);

    memset(&c, 0, sizeof(c));
    c.body_mode = KUV_BODY_CHUNKED;
    c.body_state = KUV_BODY_READING;
    c.in = strdup("3\r\nabc\r\n0\r\n\r\nNEXT");
    c.in_len = strlen(c.in);
    kiln_uv_chunk_init(&c.chunk);
    kuv_body_feed(&c);
    assert(c.body_state == KUV_BODY_DONE && c.body_len == 3);
    assert(memcmp(c.body, "abc", 3) == 0 && c.in_len == 4 && memcmp(c.in, "NEXT", 4) == 0);
    free(c.in);
    free(c.body);

    memset(&c, 0, sizeof(c));
    c.body_mode = KUV_BODY_CHUNKED;
    c.body_state = KUV_BODY_READING;
    c.in = strdup("invalid\r\n");
    c.in_len = strlen(c.in);
    kiln_uv_chunk_init(&c.chunk);
    kuv_body_feed(&c);
    assert(c.body_state == KUV_BODY_FAILED && c.body_error == 400);
    free(c.in);
    free(c.body);
    puts("ok connection transitions, read policy and body framing");

    return 0;
}
