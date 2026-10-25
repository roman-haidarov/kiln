#ifndef KILN_UV_STATE_H
#define KILN_UV_STATE_H

typedef enum kuv_conn_state {
    KUV_CONN_OPEN,
    KUV_CONN_FLUSHING,
    KUV_CONN_LINGERING,
    KUV_CONN_CLOSING,
    KUV_CONN_STATE_COUNT
} kuv_conn_state;

typedef enum kuv_conn_event {
    KUV_CONN_FINISH,
    KUV_CONN_LINGER,
    KUV_CONN_CLOSE,
    KUV_CONN_EVENT_COUNT
} kuv_conn_event;

static inline kuv_conn_state kuv_conn_next(kuv_conn_state state, kuv_conn_event event) {
    static const kuv_conn_state transitions[KUV_CONN_STATE_COUNT][KUV_CONN_EVENT_COUNT] = {
        {KUV_CONN_FLUSHING, KUV_CONN_LINGERING, KUV_CONN_CLOSING},
        {KUV_CONN_FLUSHING, KUV_CONN_LINGERING, KUV_CONN_CLOSING},
        {KUV_CONN_LINGERING, KUV_CONN_LINGERING, KUV_CONN_CLOSING},
        {KUV_CONN_CLOSING, KUV_CONN_CLOSING, KUV_CONN_CLOSING}};
    return transitions[state][event];
}

typedef enum kuv_parse_state {
    KUV_PARSE_OPEN,
    KUV_PARSE_UPGRADE,
    KUV_PARSE_STOPPED,
    KUV_PARSE_TUNNEL
} kuv_parse_state;

typedef enum kuv_body_state {
    KUV_BODY_IDLE,
    KUV_BODY_READING,
    KUV_BODY_PAUSED,
    KUV_BODY_DONE,
    KUV_BODY_FAILED
} kuv_body_state;

typedef enum kuv_expect_state {
    KUV_EXPECT_NONE,
    KUV_EXPECT_BUFFERED,
    KUV_EXPECT_SENT,
    KUV_EXPECT_STREAMED
} kuv_expect_state;

typedef enum kuv_head_state { KUV_HEAD_IDLE, KUV_HEAD_READING, KUV_HEAD_BODY } kuv_head_state;

#endif
