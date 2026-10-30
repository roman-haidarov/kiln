module Kiln
  module DB
    class Conn
      module Driving
        def usable!
          raise ConnectionError, 'connection closed' if @closed
          raise ConnectionError, 'connection broken; discard it' if @broken
        end

        def deadline_ms
          now = Native.now_ms
          limit = now + @timeout_ms
          stamp = Thread.current[:kiln_deadline]
          if !stamp.nil? && stamp.positive?
            left = ((stamp - Process.clock_gettime(Process::CLOCK_MONOTONIC)) * 1000).to_i
            raise Timeout.new('request deadline exceeded', code: Native::TIMEOUT) if left <= 0

            limit = now + left if now + left < limit
          end
          limit
        end

        def drive(operation, label)
          assert_owner!
          raise Unsupported, 'Kiln::DB on an inline event-loop handler; use handlers: N' if Thread.current[:kiln_inline]

          out = Native.drive(@handle, 1, 1, operation, deadline_ms, @waiter)
          return out if out[0] == Native::STEP_DONE

          fail_step(out, label, operation)
        end

        def fail_step(out, label, operation)
          code = out[4]
          text = "#{label} #{Native.kiln_db_error_text(@handle, 1, 1)}"
          state = Conn.sqlstate(out[5])
          if code == Native::TIMEOUT
            recover_timeout(operation)
            raise Timeout.new(text, sqlstate: state, code: code)
          end
          @broken = true if [Native::CONN, Native::OWNERSHIP, Native::BUSY].include?(code)
          @broken = true if Native.broken?(@handle, 1, 1)
          raise Conn.error_class(code).new(text, sqlstate: state, code: code)
        end

        def recover_timeout(operation)
          if operation == Native::OP_CONNECT || @kind != Native::KIND_PG
            @broken = true
            return nil
          end
          out = Native.drive(@handle, 1, 1, Native::OP_CANCEL, Native.now_ms + CANCEL_MS)
          @broken = true if out[0] != Native::STEP_DONE || Native.broken?(@handle, 1, 1)
          nil
        end
      end
    end
  end
end
