module Kiln
  class Server
    class Base
      class RequestHead
        attr_reader :version, :verb, :target, :headers, :length

        def initialize(version, verb, target, headers, length)
          @version = version
          @verb = verb
          @target = target
          @headers = headers
          @length = length
        end

        def request(body, payload)
          HTTP::Request.new(@verb, @target, @headers, body, HTTP::Request::Wire.new(@version, payload, nil))
        end
      end

      module RequestReading
        private

        def read_request(sock, buf, scan, first)
          deadline = head_deadline(sock, buf, first)
          return nil unless deadline

          len = find_head_end(sock, buf, deadline)
          return HTTP::Syntax.error_tuple(len) if len.is_a?(Symbol)

          parsed = HTTP::Native.parse_at(buf.data, buf.pos, len, scan)
          buf.skip(len + HEADER_END.bytesize)
          return HTTP::Syntax.error_tuple(parsed) if parsed.is_a?(Symbol)

          build_from_head(sock, buf, parsed)
        end

        def head_deadline(sock, buf, first)
          deadline = Kiln::Runtime.now + @header_timeout
          return deadline unless buf.empty?
          return nil if @draining

          status = wait_io(sock, buf, first ? deadline : Kiln::Runtime.now + @keep_alive_timeout)
          return nil unless status == :ok

          first ? deadline : Kiln::Runtime.now + @header_timeout
        end

        def build_from_head(sock, buf, parsed)
          version, verb, target, headers = parsed
          target = check_head(version, verb, target, headers)
          return target if target.is_a?(Array)

          length = HTTP::Syntax.content_length(headers, HTTP::Syntax::MAX_LENGTH)
          return HTTP::Syntax.error_tuple(length, version: version) if length.is_a?(Symbol)

          receive_body(sock, buf, RequestHead.new(version, verb, target, headers, length))
        end

        def receive_body(sock, buf, head)
          streamed = stream_source(sock, buf, head)
          return HTTP::Syntax.error_tuple(streamed, version: head.version) if streamed.is_a?(Symbol)
          return accepted(head.request(EMPTY_BODY, HTTP::Payload.new(streamed, head.length, @max_body))) if streamed

          body, err = read_body(sock, buf, head)
          return HTTP::Syntax.error_tuple(err, version: head.version) if err

          accepted(head.request(body, nil))
        end

        def accepted(req) = [:req, req, Kiln::Runtime.now + @request_timeout]

        def stream_source(sock, buf, head)
          coding = head.headers['transfer-encoding']
          return chunked_source(sock, buf, head, coding) if coding

          length = head.length
          return nil if length.nil? || length <= @buffer_body

          BodySource.new(self, sock, buf, length, continue?(head.headers, head.version))
        end

        def chunked_source(sock, buf, head, coding)
          problem = HTTP::RequestPolicy.chunked_problem(coding)
          return problem if problem

          BodySource.new(self, sock, buf, nil, continue?(head.headers, head.version))
        end

        def continue?(headers, version)
          HTTP::RequestPolicy.continue?(headers, version)
        end

        def check_head(version, verb, target, headers)
          problem = HTTP::RequestPolicy.head_problem(version, verb, target, headers)
          return HTTP::Syntax.error_tuple(problem, version: version) if problem

          target = HTTP::RequestPolicy.origin(target, headers)
          return HTTP::Syntax.error_tuple(:bad, version: version) unless target

          problem = HTTP::RequestPolicy.framing_problem(version, headers)
          problem ? HTTP::Syntax.error_tuple(problem, version: version) : target
        end
      end

      module RequestIo
        private

        def read_body(sock, buf, head)
          deadline = Kiln::Runtime.now + @read_timeout
          len = head.length || 0
          return [EMPTY_BODY, nil] if len.zero?

          maybe_continue(sock, buf, head, buf.size < len)
          err = read_exact(sock, buf, deadline, len)
          return [nil, err] if err

          [buf.take(len), nil]
        end

        def maybe_continue(sock, buf, head, pending)
          return unless pending && continue?(head.headers, head.version)

          outbox = buf.outbox
          continue_deadline = Kiln::Runtime.now + 1.0
          if outbox && !flush_outbox(sock, outbox, continue_deadline)
            raise IOError, 'pipelined responses could not be sent'
          end
          raise IOError, '100 Continue could not be sent' unless write_all(sock, CONTINUE, continue_deadline)
        end

        def read_exact(sock, buf, deadline, len)
          while buf.size < len
            status = wait_io(sock, buf, deadline)
            return :timeout if status == :timeout
            return :bad unless status == :ok
          end
          nil
        end

        def find_head_end(sock, buf, deadline)
          marker_size = HEADER_END.bytesize
          from = 0
          loop do
            at = buf.index(HEADER_END, from)
            return at > MAX_HEADER ? :too_big : at if at
            return :too_big if buf.size > MAX_HEADER + marker_size

            from = [buf.size - marker_size + 1, 0].max
            status = wait_io(sock, buf, deadline)
            return status == :timeout ? :timeout : :bad unless status == :ok
          end
        end

        def wait_io(sock, buf, deadline)
          loop do
            return :timeout if Kiln::Runtime.now >= deadline

            chunk = HTTP::Native.kiln_recv(sock.fileno, 16_384)
            return received(buf, chunk) unless chunk.empty?
            return :eof unless HTTP::Native.kiln_recv_status == -1

            flush_pending(sock, buf, deadline)
            return :timeout unless readable_before?(sock, deadline)
          end
        rescue IOError, SystemCallError
          :eof
        end

        def received(buf, chunk)
          buf.append(chunk)
          :ok
        end

        def flush_pending(sock, buf, deadline)
          box = buf.outbox
          return unless box && !box.empty? && !flush_outbox(sock, box, deadline)

          raise IOError, 'pipelined responses could not be sent'
        end
      end

      module BodyPulling
        def body_pull(src, max)
          return nil if src.state == :done

          sock = src.sock
          buf = src.buf
          send_continue(sock, buf) if src.expect
          src.expect = false
          deadline = pull_deadline
          return pull_length(src, sock, buf, max, deadline) if src.length

          pull_chunked(src, sock, buf, max, deadline)
        end

        private

        def pull_deadline
          limit = Kiln::Runtime.now + @read_timeout
          request = Kiln::Runtime.deadline
          return limit unless request.positive?
          raise Runtime::DeadlineExceeded, 'deadline exceeded' if request <= Kiln::Runtime.now

          [request, limit].min
        end

        def send_continue(sock, buf)
          outbox = buf.outbox
          limit = Kiln::Runtime.now + 1.0
          if outbox && !flush_outbox(sock, outbox, limit)
            raise Runtime::ClientGone, 'pipelined responses could not be sent'
          end
          raise Runtime::ClientGone, '100 Continue could not be sent' unless write_all(sock, CONTINUE, limit)
        end

        def body_wait(sock, buf, deadline)
          status = wait_io(sock, buf, deadline)
          return if status == :ok

          request_expired = Kiln::Runtime.deadline.positive? && Kiln::Runtime.now >= Kiln::Runtime.deadline
          raise Runtime::DeadlineExceeded, 'deadline exceeded' if status == :timeout && request_expired
          raise HTTP::RequestTimeout, 'request body timeout' if status == :timeout

          raise Runtime::ClientGone, 'client went away while sending the body'
        end

        def pull_length(src, sock, buf, max, deadline)
          left = src.remaining
          return finish_source(src, nil) if left.zero?

          body_wait(sock, buf, deadline) if buf.empty?
          take = [buf.size, left, max].min
          src.remaining = left - take
          src.state = :done if src.remaining.zero?
          buf.take(take)
        end

        def finish_source(src, piece)
          src.state = :done
          piece.nil? || piece.empty? ? nil : piece
        end

        def pull_chunked(src, sock, buf, max, deadline)
          return (+'').b unless max.positive?

          state = src.chunk_state
          loop do
            body_wait(sock, buf, deadline) if buf.empty?
            piece = chunk_step(buf, max, state)
            return finish_source(src, piece) if state[5] == CHUNK_END
            return piece unless piece.empty?

            body_wait(sock, buf, deadline) if state[4].zero?
          end
        end

        def chunk_step(buf, max, state)
          data = buf.data
          piece = HTTP::Native.kiln_chunk_step(data, data.bytesize, buf.pos, max, state)
          used = state[4]
          buf.skip(used) if used.positive?
          check_chunk_status(state[5])
          piece
        end

        def check_chunk_status(status)
          raise HTTP::TrailersTooLarge, 'trailers too large' if status == CHUNK_TOO_BIG
          raise HTTP::PayloadTooLarge, 'payload too large' if status == CHUNK_HUGE
          raise HTTP::BadRequest, 'malformed chunked body' if status.negative?
        end
      end

      include RequestReading
      include RequestIo
      include BodyPulling
    end
  end
end
