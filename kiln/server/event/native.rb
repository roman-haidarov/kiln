module Kiln
  module Uv
    ffi_lib 'dl'
    ffi_lib 'pthread'
    ffi_func :kiln_uv_create, [], :long
    ffi_func :kiln_uv_destroy, [:long], :long
    ffi_func :kiln_uv_configure, %i[long int_array long], :long
    ffi_func :kiln_uv_adopt, %i[long long long], :long
    ffi_func :kiln_uv_start, [:long], :long
    ffi_func :kiln_uv_abandon, [:long], :long
    ffi_func :kiln_uv_error_text, [:long], :binstr
    ffi_func :kiln_uv_running, [:long], :long
    ffi_func :kiln_uv_port, [:long, :long], :long
    ffi_func :kiln_uv_fd, [:long], :long
    ffi_func :kiln_uv_poll, [:long], :long
    ffi_func :kiln_uv_settle, [:long], :long
    ffi_func :kiln_uv_timeout, [:long], :long
    ffi_func :kiln_uv_next, %i[long int_array long int_array], :binstr
    ffi_func :kiln_uv_send, %i[long long long str long str long long], :long
    ffi_func :kiln_uv_abort, %i[long long long], :long
    ffi_func :kiln_uv_end, %i[long long long], :long
    ffi_func :kiln_uv_part, %i[long long long str long], :long
    ffi_func :kiln_uv_backlog, %i[long long long], :long
    ffi_func :kiln_uv_refuse, %i[long long long], :long
    ffi_func :kiln_uv_flush, [:long], :long
    ffi_func :kiln_uv_open, [:long], :long
    ffi_func :kiln_uv_stop, [:long], :long
    ffi_func :kiln_uv_wake, [:long], :long
    ffi_func :kiln_uv_drain, [:long], :long
    ffi_func :kiln_uv_busy, [:long], :long
    ffi_func :kiln_uv_aborted, [:long], :long
    ffi_func :kiln_uv_handshakes, [:long], :long
    ffi_func :kiln_uv_closes_after, %i[long long long long], :long
    ffi_func :kiln_uv_body_take, %i[long long long long int_array], :binstr
    ffi_func :kiln_uv_body_finish, %i[long long long long], :long
    ffi_func :kiln_uv_tunnel, %i[long long long str long], :long
    ffi_func :kiln_uv_tls_alpn, %i[long long long], :binstr
    ffi_func :kiln_uv_sigpipe_enter, [], :long
    ffi_func :kiln_uv_sigpipe_leave, [], :long

    class Loop
      def initialize
        @handle = Uv.kiln_uv_create
        raise NoMemoryError, 'cannot allocate event loop' if @handle.zero?
      end

      def close
        return if @handle.zero?

        rc = Uv.kiln_uv_destroy(@handle)
        raise IOError, "cannot release event loop (#{rc})" unless rc.zero?

        @handle = 0
      end

      def kiln_uv_configure(cfg, n) = Uv.kiln_uv_configure(@handle, cfg, n)
      def kiln_uv_adopt(fd, tls) = Uv.kiln_uv_adopt(@handle, fd, tls)
      def kiln_uv_start = Uv.kiln_uv_start(@handle)
      def kiln_uv_abandon = Uv.kiln_uv_abandon(@handle)
      def kiln_uv_running = Uv.kiln_uv_running(@handle)
      def kiln_uv_port(index) = Uv.kiln_uv_port(@handle, index)
      def kiln_uv_fd = Uv.kiln_uv_fd(@handle)
      def kiln_uv_poll = Uv.kiln_uv_poll(@handle)
      def kiln_uv_settle = Uv.kiln_uv_settle(@handle)
      def kiln_uv_timeout = Uv.kiln_uv_timeout(@handle)
      def kiln_uv_next(scan, cap, meta) = Uv.kiln_uv_next(@handle, scan, cap, meta)
      def kiln_uv_send(slot, gen, head, head_len, body, body_len, close_after) = Uv.kiln_uv_send(@handle, slot, gen, head, head_len, body, body_len, close_after)
      def kiln_uv_part(slot, gen, data, len) = Uv.kiln_uv_part(@handle, slot, gen, data, len)
      def kiln_uv_backlog(slot, gen) = Uv.kiln_uv_backlog(@handle, slot, gen)
      def kiln_uv_refuse(slot, gen) = Uv.kiln_uv_refuse(@handle, slot, gen)
      def kiln_uv_abort(slot, gen) = Uv.kiln_uv_abort(@handle, slot, gen)
      def kiln_uv_end(slot, gen) = Uv.kiln_uv_end(@handle, slot, gen)
      def kiln_uv_closes_after(slot, gen, stopping) = Uv.kiln_uv_closes_after(@handle, slot, gen, stopping)
      def kiln_uv_body_take(slot, gen, max, state) = Uv.kiln_uv_body_take(@handle, slot, gen, max, state)
      def kiln_uv_body_finish(slot, gen, failed) = Uv.kiln_uv_body_finish(@handle, slot, gen, failed)
      def kiln_uv_tunnel(slot, gen, head, head_len) = Uv.kiln_uv_tunnel(@handle, slot, gen, head, head_len)
      def kiln_uv_tls_alpn(slot, gen) = Uv.kiln_uv_tls_alpn(@handle, slot, gen)
      def kiln_uv_flush = Uv.kiln_uv_flush(@handle)
      def kiln_uv_open = Uv.kiln_uv_open(@handle)
      def kiln_uv_aborted = Uv.kiln_uv_aborted(@handle)
      def kiln_uv_handshakes = Uv.kiln_uv_handshakes(@handle)
      def kiln_uv_stop = Uv.kiln_uv_stop(@handle)
      def kiln_uv_wake = Uv.kiln_uv_wake(@handle)
      def kiln_uv_drain = Uv.kiln_uv_drain(@handle)
      def kiln_uv_busy = Uv.kiln_uv_busy(@handle)
    end
  end

end
