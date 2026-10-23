module Kiln
  module DB
    module Native
      OK = 0
      ERR = 1
      STALE = 2
      CAPACITY = 4
      TIMEOUT = 5
      UNSUPPORTED = 6
      CONFIG = 7
      CONN = 8
      UNIQUE = 9
      FK = 10
      NOTNULL = 11
      CHECK = 12
      DEADLOCK = 13
      SERIAL = 14
      BUSY = 16
      LOCKWAIT = 17
      OWNERSHIP = 3
      T_TEXT = 0
      T_INT = 1
      T_FLOAT = 2
      T_DECIMAL = 3
      T_BOOL = 4
      T_BINARY = 5
      T_UINT = 6
      STEP_DONE = 0
      STEP_WAIT = 1
      STEP_ERR = 2
      READY_READ = 1
      READY_WRITE = 2
      READY_BOTH = 3
      READY_TIMEOUT = 4
      KIND_PG = 1
      KIND_MY = 2
      OP_CONNECT = 1
      OP_EXEC = 2
      OP_DRAIN = 3
      OP_CANCEL = 4
      OP_CLOSE = 5
      OP_BEGIN = 6
      OP_COMMIT = 7
      OP_ROLLBACK = 8
      OP_PREPARE = 16
      OP_PIPELINE_SYNC = 15
      OP_PIPELINE_ENTER = 17
      OP_PIPELINE_EXIT = 18
      OP_PIPELINE_QUERY = 19
      OP_PIPELINE_TAKE = 20
      SSL_VERIFY_FULL = 1
      SSL_DISABLE = 2
      NUM_ADD = 1
      NUM_SUB = 2
      NUM_MUL = 3
      NUM_DIV = 4
      NUM_MOD = 5
      NUM_NEG = 6

      ffi_func :kiln_db_configure_values, %i[int_array int], :int
      ffi_func :kiln_db_now_ms, [], :long
      ffi_func :kiln_db_load_kind, [:int], :int
      ffi_func :kiln_db_client_version, [:int], :long
      ffi_func :kiln_db_caps, [:int], :long
      ffi_func :kiln_db_load_error, [], :str
      ffi_func :kiln_db_conn_create, %i[int long long int_array], :long
      ffi_func :kiln_db_conn_set, %i[long long long str long int str long str long str long int str long int str long],
               :int
      ffi_func :kiln_db_set_sql, %i[long long long str long], :int
      ffi_func :kiln_db_set_format, %i[long long long int int], :int
      ffi_func :kiln_db_bind_str, %i[long long long int str long int int], :int
      ffi_func :kiln_db_result_types, %i[long long long int_array int], :int
      ffi_func :kiln_db_result_row, %i[long long long long int_array int], :binstr
      ffi_func :kiln_db_conn_broken, %i[long long long], :int
      ffi_func :kiln_db_os_thread_token, [], :long
      ffi_func :kiln_db_dns_submit, %i[str long int_array int], :int
      ffi_func :kiln_db_dns_take, %i[int int_array int], :str
      ffi_func :kiln_db_resolver_cancel, [:int], :int
      ffi_func :kiln_db_conn_set_hostaddr, %i[long long long str long], :int
      ffi_func :kiln_db_step, %i[long long long int int long int_array int], :int
      ffi_func :kiln_db_result_meta, %i[long long long int_array int], :int
      ffi_func :kiln_db_result_bytes, %i[long long long long long int_array int], :binstr
      ffi_func :kiln_db_error_text, %i[long long long], :str
      ffi_func :kiln_db_peer_id, %i[long long long], :long
      ffi_func :kiln_db_i64_parse, %i[str int_array int], :int
      ffi_func :kiln_db_u64_parse, %i[str int_array int], :int
      ffi_func :kiln_db_i64_apply, %i[int long long long long int_array int], :int
      ffi_func :kiln_db_u64_apply, %i[int long long long long int_array int], :int
      ffi_func :kiln_db_i64_cmp_text, %i[long long str int_array int], :int
      ffi_func :kiln_db_u64_cmp_text, %i[long long str int_array int], :int
      ffi_func :kiln_db_i64_text, %i[long long], :str
      ffi_func :kiln_db_u64_text, %i[long long], :str
      ffi_func :kiln_db_block_open, %i[long long long long int_array int int_array int], :int
      ffi_func :kiln_db_block_close, %i[long long long long], :int
      ffi_func :kiln_db_block_import, %i[long long long long long int_array int], :int
      ffi_func :kiln_db_copy_i64, %i[long long long long int_array int], :int
      ffi_func :kiln_db_copy_null_rows, %i[long long long long int_array int], :int
      ffi_func :kiln_db_block_text, %i[long long long long int_array int int_array int int_array int], :binstr

      module Calls
        def configure
          values = [65_536, 1024, 4096, 67_108_864, 8, 64, 16, 5000]
          Native.kiln_db_configure_values(values, 8)
        end

        def now_ms
          Native.kiln_db_now_ms
        end

        def load_kind(kind)
          Native.kiln_db_load_kind(kind)
        end

        def client_version(kind)
          Native.kiln_db_client_version(kind)
        end

        def pg_hostaddr(host, deadline_ms)
          out = [0, 0, 0]
          rc = Native.kiln_db_dns_submit(host, host.bytesize, out, 3)
          raise ConnectionError, 'DNS submission failed' unless rc == OK
          return host if out[2] == 1

          await_dns(out[0], out[1], deadline_ms)
        end

        def await_dns(request, socket_fd, deadline_ms)
          loop do
            state = [0]
            resolved = Native.kiln_db_dns_take(request, state, 1)
            return resolved if state[0] == OK
            raise ConnectionError, 'DNS lookup failed' unless state[0] == BUSY

            dns_wait(request, socket_fd, deadline_ms - now_ms)
          end
        end

        def dns_wait(request, socket_fd, remaining)
          if remaining <= 0
            Native.kiln_db_resolver_cancel(request)
            raise Timeout.new('DNS lookup timed out', code: TIMEOUT)
          end
          IO.for_fd(socket_fd, autoclose: false).wait_readable(remaining * 0.001)
        end

        def set_hostaddr(handle, scope, thread_id, address)
          Native.kiln_db_conn_set_hostaddr(handle, scope, thread_id, address, address.bytesize)
        end

        def peer_id(handle, scope, thread_id)
          Native.kiln_db_peer_id(handle, scope, thread_id)
        end

        def open_conn(kind, scope, thread_id)
          err = [0]
          handle = Native.kiln_db_conn_create(kind, scope, thread_id, err)
          [handle, err[0]]
        end

        def connect_params(handle, scope, thread_id, endpoint)
          endpoint.apply_to(handle, scope, thread_id)
        end

        def set_sql(handle, scope, thread_id, sql)
          Native.kiln_db_set_sql(handle, scope, thread_id, sql, sql.bytesize)
        end

        def set_format(handle, scope, thread_id, format, chunk)
          Native.kiln_db_set_format(handle, scope, thread_id, format, chunk)
        end

        def bind_str(handle, scope, thread_id, index, encoded)
          text, is_null, format = encoded
          return Native.kiln_db_bind_str(handle, scope, thread_id, index, '', 0, 1, format) if is_null == 1 || text.nil?

          Native.kiln_db_bind_str(handle, scope, thread_id, index, text, text.bytesize, 0, format)
        end

        def bind_bytes(handle, owner, index, bytes, flags)
          text = bytes.nil? ? '' : bytes.pack('C*')
          bind_str(handle, owner[0], owner[1], index, [text, bytes.nil? ? 1 : flags[0], flags[1]])
        end

        def result_types(handle, scope, thread_id, width)
          out = Array.new(width, 0)
          Native.kiln_db_result_types(handle, scope, thread_id, out, width)
          out
        end

        def result_row(handle, scope, thread_id, row, lens)
          bytes = Native.kiln_db_result_row(handle, scope, thread_id, row, lens, lens.length)
          raise ConnectionError, 'database row unavailable or invalid' if lens.length.positive? && lens[0] == -2

          bytes
        end

        def broken?(handle, scope, thread_id)
          Native.kiln_db_conn_broken(handle, scope, thread_id) != 0
        end

        def os_thread_token
          Native.kiln_db_os_thread_token
        end

        def result_meta(handle, scope, thread_id)
          out = [0, 0, 0, 0, 0]
          Native.kiln_db_result_meta(handle, scope, thread_id, out, 5)
          out
        end

        def result_bytes(handle, scope, thread_id, row, col)
          meta = [0, 0]
          bytes = Native.kiln_db_result_bytes(handle, scope, thread_id, row, col, meta, 2)
          raise ConnectionError, 'database cell unavailable or invalid' if meta[0] == -2

          [bytes, meta[0], meta[1]]
        end
      end

      module Blocks
        def block_open(scope, thread_id, rows, cols, kinds)
          out = [0, 0]
          rc = Native.kiln_db_block_open(scope, thread_id, rows, cols, kinds, kinds.length, out, 2)
          [rc, out[0], out[1]]
        end

        def block_close(block, arena, scope, thread_id)
          Native.kiln_db_block_close(block, arena, scope, thread_id)
        end

        def block_import(conn, block, owner, dest_row, out)
          Native.kiln_db_block_import(conn, block, owner[0], owner[1], dest_row, out, 2)
        end

        def copy_i64(block, scope, thread_id, col, dst)
          Native.kiln_db_copy_i64(block, scope, thread_id, col, dst, dst.length)
        end

        def copy_null_rows(block, scope, thread_id, col, dst)
          Native.kiln_db_copy_null_rows(block, scope, thread_id, col, dst, dst.length)
        end

        def block_text(block, owner, col, buffers)
          offs, lens, meta = buffers
          Native.kiln_db_block_text(block, owner[0], owner[1], col, offs, offs.length, lens, lens.length, meta, 2)
        end

        def i64_parse(text, words)
          Native.kiln_db_i64_parse(text, words, 2)
        end
      end

      module Driving
        def park(socket_fd, bits, wait_ms, remain_ms)
          seconds = (wait_ms.positive? && wait_ms < remain_ms ? wait_ms : remain_ms) * 0.001
          if socket_fd.negative?
            sleep(seconds)
            return READY_TIMEOUT
          end
          wait_ready(IO.for_fd(socket_fd, autoclose: false), bits, seconds)
        end

        def wait_ready(io, bits, seconds)
          return ready_or_timeout(io.wait(seconds, :read_write), READY_BOTH) if bits == READY_BOTH
          return ready_or_timeout(io.wait_writable(seconds), READY_WRITE) if bits == READY_WRITE

          ready_or_timeout(io.wait_readable(seconds), READY_READ)
        end

        def ready_or_timeout(got, ready) = got.nil? ? READY_TIMEOUT : ready

        def drive(handle, scope, thread_id, operation, deadline_ms)
          out = [0, 0, 0, 0, 0, 0, 0, 0]
          ready = 0
          loop do
            Native.kiln_db_step(handle, scope, thread_id, operation, ready, deadline_ms, out, 8)
            return out if out[0] != STEP_WAIT

            remain = deadline_ms - now_ms
            return timed_out_step(out) if remain <= 0

            ready = park(out[1], out[2], out[3], remain)
          end
        end

        def timed_out_step(out)
          out[0] = STEP_ERR
          out[4] = TIMEOUT
          out
        end
      end

      extend Calls
      extend Blocks
      extend Driving
    end
  end
end
