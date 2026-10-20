module Kiln
  class Server
    class Base
      private

      def read_request(sock, buf, scan, first)
        deadline = Kiln.now + @header_timeout
        if buf.empty?
          return nil if @draining

          status = wait_io(sock, buf, first ? deadline : Kiln.now + @keep_alive_timeout)
          return nil unless status == :ok

          deadline = Kiln.now + @header_timeout unless first
        end

        len = find_marker(sock, buf, deadline, HEADER_END, MAX_HEADER, :too_big)
        return HttpSyntax.error_tuple(len) if len.is_a?(Symbol)

        parsed = HttpNative.parse_at(buf.data, buf.pos, len, scan)
        buf.skip(len + HEADER_END.bytesize)
        return HttpSyntax.error_tuple(parsed) if parsed.is_a?(Symbol)

        version, verb, target, headers = parsed
        target = check_head(version, verb, target, headers)
        return target if target.is_a?(Array)

        length = HttpSyntax.content_length(headers, HttpSyntax::MAX_LENGTH)
        return HttpSyntax.error_tuple(length, version: version) if length.is_a?(Symbol)

        streamed = stream_source(sock, buf, headers, length, version)
        return HttpSyntax.error_tuple(streamed, version: version) if streamed.is_a?(Symbol)

        if streamed
          payload = Payload.new(streamed, length, @max_body)
          req = Request.new(verb, target, headers, EMPTY_BODY, http_version: version, payload: payload)
          return [:req, req, Kiln.now + @request_timeout]
        end
        body, err = read_body(sock, buf, Kiln.now + @read_timeout, headers, length, version)
        return HttpSyntax.error_tuple(err, version: version) if err

        [:req, Request.new(verb, target, headers, body, http_version: version), Kiln.now + @request_timeout]
      end

      def stream_source(sock, buf, headers, length, version)
        coding = headers['transfer-encoding']
        if coding
          codings = coding.split(',', -1).map { |item| item.strip.downcase }
          return :bad if codings.any?(&:empty?) || codings.last != 'chunked' || codings.count('chunked') > 1
          return :unsupported_te if codings.size > 1

          return BodySource.new(self, sock, buf, nil, continue?(headers, version))
        end
        return nil if length.nil? || length <= @buffer_body

        BodySource.new(self, sock, buf, length, continue?(headers, version))
      end

      def continue?(headers, version)
        version == '1.1' && headers['expect'].to_s.split(',').any? { |part| part.strip.casecmp?('100-continue') }
      end

      def check_head(version, verb, target, headers)
        return HttpSyntax.error_tuple(:not_implemented, version: version) if verb == 'CONNECT'

        unrooted = !target.start_with?('/')
        absolute_form = unrooted && target.match?(HttpSyntax::ABSOLUTE_FORM)
        if target == '*'
          return HttpSyntax.error_tuple(:bad, version: version) unless verb == 'OPTIONS'
        elsif unrooted && !absolute_form
          return HttpSyntax.error_tuple(:bad, version: version)
        end
        absolute = absolute_form
        host = headers['host']
        missing_host = host.nil?
        empty_host = !missing_host && host.empty?
        invalid_host = missing_host || (!absolute && empty_host)
        return HttpSyntax.error_tuple(:bad, version: version) if version == '1.1' && invalid_host
        return HttpSyntax.error_tuple(:bad, version: version) if host && !empty_host && !HttpNative.host?(host)

        if absolute
          target, authority = HttpSyntax.absolute_target(target)
          return HttpSyntax.error_tuple(:bad, version: version) unless target

          headers['host'] = authority
        end
        invalid_framing = headers.key?('transfer-encoding') &&
                          (version == '1.0' || headers.key?('content-length'))
        return HttpSyntax.error_tuple(:bad, version: version) if invalid_framing

        expect = headers['expect']
        if expect && !expect.empty? && expect.strip.downcase != '100-continue'
          return HttpSyntax.error_tuple(:expectation, version: version)
        end

        target
      end

      public

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
        limit = Kiln.now + @read_timeout
        request = Kiln.deadline
        return limit unless request.positive?
        raise DeadlineExceeded, 'deadline exceeded' if request <= Kiln.now

        request < limit ? request : limit
      end

      def send_continue(sock, buf)
        outbox = buf.outbox
        limit = Kiln.now + 1.0
        raise ClientGone, 'pipelined responses could not be sent' if outbox && !flush_outbox(sock, outbox, limit)
        raise ClientGone, '100 Continue could not be sent' unless write_all(sock, CONTINUE, limit)
      end

      def body_wait(sock, buf, deadline)
        status = wait_io(sock, buf, deadline)
        return if status == :ok

        request_expired = Kiln.deadline.positive? && Kiln.now >= Kiln.deadline
        raise DeadlineExceeded, 'deadline exceeded' if status == :timeout && request_expired
        raise RequestTimeout, 'request body timeout' if status == :timeout

        raise ClientGone, 'client went away while sending the body'
      end

      def pull_length(src, sock, buf, max, deadline)
        left = src.remaining
        if left.zero?
          src.state = :done
          return nil
        end
        body_wait(sock, buf, deadline) if buf.empty?
        take = buf.size
        take = left if left < take
        take = max if max < take
        src.remaining = left - take
        src.state = :done if src.remaining.zero?
        buf.take(take)
      end

      def pull_chunked(src, sock, buf, max, deadline)
        return (+'').b unless max.positive?

        state = src.chunk_state
        loop do
          body_wait(sock, buf, deadline) if buf.empty?
          data = buf.data
          piece = HttpNative.kiln_chunk_step(data, data.bytesize, buf.pos, max, state)
          used = state[4]
          buf.skip(used) if used.positive?
          status = state[5]
          raise TrailersTooLarge, 'trailers too large' if status == CHUNK_TOO_BIG
          raise PayloadTooLarge, 'payload too large' if status == CHUNK_HUGE
          raise BadRequest, 'malformed chunked body' if status.negative?

          if status == CHUNK_END
            src.state = :done
            return piece.empty? ? nil : piece
          end
          return piece unless piece.empty?

          body_wait(sock, buf, deadline) if used.zero?
        end
      end

      def read_body(sock, buf, deadline, headers, len, version)
        len ||= 0
        return [EMPTY_BODY, nil] if len.zero?

        maybe_continue(sock, headers, buf.size < len, version, buf)
        err = read_exact(sock, buf, deadline, len)
        return [nil, err] if err

        [buf.take(len), nil]
      end

      def maybe_continue(sock, headers, pending, version, buf)
        return unless pending && continue?(headers, version)

        outbox = buf.outbox
        continue_deadline = Kiln.now + 1.0
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

      def find_marker(sock, buf, deadline, marker, max, overflow)
        from = 0
        marker_size = marker.bytesize
        limit = max + marker_size
        loop do
          at = buf.index(marker, from)
          if at
            return overflow if at > max

            return at
          end
          size = buf.size
          return overflow if size > limit

          from = size - marker_size + 1
          from = 0 if from.negative?
          status = wait_io(sock, buf, deadline)
          return :timeout if status == :timeout
          return :bad unless status == :ok
        end
      end

      def wait_io(sock, buf, deadline)
        fd = sock.fileno
        loop do
          return :timeout if Kiln.now >= deadline

          chunk = HttpNative.kiln_recv(fd, 16_384)
          unless chunk.empty?
            buf.append(chunk)
            return :ok
          end
          status = HttpNative.kiln_recv_status
          return :eof unless status == -1

          box = buf.outbox
          if box && !box.empty? && !flush_outbox(sock, box, deadline)
            raise IOError, 'pipelined responses could not be sent'
          end

          left = deadline - Kiln.now
          return :timeout if left <= 0

          ready, = IO.select([sock], nil, nil, left)
          return :timeout unless ready
        end
      rescue IOError, SystemCallError
        :eof
      end
    end
  end
end
