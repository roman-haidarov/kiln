module Kiln
  module Uv
    ffi_lib 'dl'
    ffi_lib 'pthread'
    ffi_func :kiln_uv_configure, %i[int_array long], :long
    ffi_func :kiln_uv_adopt, %i[long long], :long
    ffi_func :kiln_uv_start, [], :long
    ffi_func :kiln_uv_abandon, [], :long
    ffi_func :kiln_uv_error_text, [:long], :binstr
    ffi_func :kiln_uv_running, [], :long
    ffi_func :kiln_uv_port, [:long], :long
    ffi_func :kiln_uv_fd, [], :long
    ffi_func :kiln_uv_poll, [], :long
    ffi_func :kiln_uv_settle, [], :long
    ffi_func :kiln_uv_timeout, [], :long
    ffi_func :kiln_uv_next, %i[int_array long int_array], :binstr
    ffi_func :kiln_uv_send, %i[long long str long str long long], :long
    ffi_func :kiln_uv_abort, %i[long long], :long
    ffi_func :kiln_uv_end, %i[long long], :long
    ffi_func :kiln_uv_part, %i[long long str long], :long
    ffi_func :kiln_uv_backlog, %i[long long], :long
    ffi_func :kiln_uv_refuse, %i[long long], :long
    ffi_func :kiln_uv_flush, [], :long
    ffi_func :kiln_uv_open, [], :long
    ffi_func :kiln_uv_stop, [], :long
    ffi_func :kiln_uv_wake, [], :long
    ffi_func :kiln_uv_drain, [], :long
    ffi_func :kiln_uv_busy, [], :long
    ffi_func :kiln_uv_aborted, [], :long
    ffi_func :kiln_uv_handshakes, [], :long
    ffi_func :kiln_uv_closes_after, %i[long long long], :long
    ffi_func :kiln_uv_body_take, %i[long long long int_array], :binstr
    ffi_func :kiln_uv_body_finish, %i[long long long], :long
    ffi_func :kiln_uv_tunnel, %i[long long str long], :long
    ffi_func :kiln_uv_tls_alpn, %i[long long], :binstr
    ffi_func :kiln_uv_sigpipe_enter, [], :long
    ffi_func :kiln_uv_sigpipe_leave, [], :long
  end

end
