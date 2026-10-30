extern _Thread_local int sp_worker_id;

long kiln_ci_worker_id(void) {
    return sp_worker_id;
}
