module Kiln
  module Transport
    module Sock
      ffi_func :kiln_sock_tcp, %i[str long long long], :long
      ffi_func :kiln_sock_unix, %i[str long long], :long
      ffi_func :kiln_sock_kind, [:long], :long
      ffi_func :kiln_sock_port, [:long], :long
      ffi_func :kiln_sock_accept, %i[long long], :long
      ffi_func :kiln_sock_shutdown, %i[long long], :long
      ffi_func :kiln_sock_close, [:long], :long
      ffi_func :kiln_sock_unlink, [:str], :long
      ffi_func :kiln_sock_path_id, %i[str int_array], :long
      ffi_func :kiln_sock_unlink_owned, %i[str long long], :long
      ffi_func :kiln_sock_inherited, [], :long
      ffi_func :kiln_sock_ignore_sigpipe, [], :long
      ffi_func :kiln_sock_errno_text, [:long], :binstr
      ffi_func :kiln_tls_available, [], :long
      ffi_func :kiln_tls_error_text, [], :binstr
      ffi_func :kiln_tls_context_new, %i[str str str long str str long str], :long
      ffi_func :kiln_tls_context_free, [:long], :long

      FIRST_FD = 3
      EAGAIN = -11

      class << self
        def failure(what, code) = IOError.new("#{what}: #{Sock.kiln_sock_errno_text(code)} (#{code})")

        def inherited_fds
          count = Sock.kiln_sock_inherited
          Array.new(count) { |index| FIRST_FD + index }
        end

        def eagain?(code) = [EAGAIN, -35].include?(code)

        def own_path(path)
          identity = [0, 0]
          rc = Sock.kiln_sock_path_id(path, identity)
          raise failure("cannot identify unix socket #{path}", rc) if rc.negative?

          [path, identity[0], identity[1]]
        end

        def unlink_owned(path_record)
          Sock.kiln_sock_unlink_owned(path_record[0], path_record[1], path_record[2])
        end
      end
    end
  end
end
