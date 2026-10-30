#include "db/kiln_db.h"

#include <errno.h>
#include <poll.h>

extern int sp_sched_wait_io_timeout(int fd, short events, double timeout_s);
extern void sp_sched_ev_forget(int fd);

int kiln_db_wait_fd(int fd, int bits, double seconds) {
    short events = 0;
    struct pollfd slot;
    int ready;
    if (fd < 0 || seconds < 0.0) {
        return KILN_DB_READY_TIMEOUT;
    }
    if ((bits & KILN_DB_READY_READ) != 0) {
        events = (short)(events | POLLIN);
    }
    if ((bits & KILN_DB_READY_WRITE) != 0) {
        events = (short)(events | POLLOUT);
    }
    if (events == 0) {
        return KILN_DB_READY_TIMEOUT;
    }
    if (seconds == 0.0) {
        slot.fd = fd;
        slot.events = events;
        slot.revents = 0;
        do {
            ready = poll(&slot, 1, 0);
        } while (ready < 0 && errno == EINTR);
    } else {
        ready = sp_sched_wait_io_timeout(fd, events, seconds);
    }
    sp_sched_ev_forget(fd);
    if (ready > 0) {
        return bits;
    }
    return KILN_DB_READY_TIMEOUT;
}
