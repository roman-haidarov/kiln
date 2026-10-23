module Kiln
  class Server
    class Base
      private

      def linger(sock)
        Transport::Sock.kiln_sock_shutdown(sock.fileno, 1)
        drain_input(sock, Kiln::Runtime.now + @linger)
      rescue IOError, SystemCallError
        nil
      end

      def drain_input(sock, limit)
        drained = 0
        while drained < LINGER_BYTES
          chunk = sock.read_nonblock(16_384, exception: false)
          if chunk == :wait_readable
            break unless readable_before?(sock, limit)
          else
            break if chunk.nil?

            drained += chunk.bytesize
          end
        end
      end

      def readable_before?(sock, limit)
        left = limit - Kiln::Runtime.now
        left.positive? && !sock.wait_readable(left).nil?
      end

      def log_accept_error(error, delay)
        @log.error("accept error: #{error.class}: #{error.message}; retrying in #{delay}s")
      rescue *Kiln::Runtime::FAILURES
        nil
      end

      def write_all(sock, data, deadline, body = EMPTY_BODY)
        off = 0
        total = data.bytesize + body.bytesize
        off = write_step(sock, data, body, off, deadline) while off.between?(0, total - 1)
        off == total
      rescue IOError, SystemCallError
        false
      end

      def write_step(sock, data, body, off, deadline)
        return -1 if Kiln::Runtime.now >= deadline

        sent = HTTP::Native.kiln_sendv(sock.fileno, data, data.bytesize, body, body.bytesize, off)
        return off + sent if sent >= 0

        sent == -1 && writable_before?(sock, deadline) ? off : -1
      end

      def writable_before?(sock, deadline)
        left = deadline - Kiln::Runtime.now
        left.positive? && !sock.wait_writable(left).nil?
      end

      def fixed_headers
        headers = HTTP::Headers.new
        headers.plain
        headers
      end

      def write_fixed(sock, status, message, deadline, version = '1.1')
        wire = HTTP::Response.build_wire(status, fixed_headers, "#{message}\n", false, version: version)
        write_all(sock, wire, deadline)
      end

      def close_quietly(sock)
        return unless sock && !sock.closed?

        sock.close
      rescue IOError, SystemCallError
        nil
      end

      def quiet_join(thread)
        limit = Kiln::Runtime.now + 0.5
        Kernel.sleep 0.01 while thread.alive? && Kiln::Runtime.now < limit
        !thread.alive?
      rescue *Kiln::Runtime::FAILURES
        nil
      end

      def flush_outbox(sock, box, deadline)
        return true if box.empty?

        sent = write_all(sock, box.data, deadline)
        box.reset
        sent
      end

      def safe_io
        yield
      rescue IOError, SystemCallError
        nil
      end
    end
  end
end
