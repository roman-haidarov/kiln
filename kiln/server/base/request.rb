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
        loop do
          case src.state
          when :size
            return nil if chunk_size(src, sock, buf, deadline)
          when :data
            body_wait(sock, buf, deadline) if buf.empty?
            take = buf.size
            take = src.chunk_left if src.chunk_left < take
            take = max if max < take
            src.chunk_left -= take
            src.state = :crlf if src.chunk_left.zero?
            return buf.take(take)
          else
            chunk_end(src, sock, buf, deadline)
          end
        end
      end

      def chunk_size(src, sock, buf, deadline)
        line, err = read_line(sock, buf, deadline, 4096)
        raise_body(err) if err
        size = HttpNative.kiln_chunk_size(line, line.bytesize, HttpSyntax::MAX_LENGTH)
        raise BadRequest, 'malformed chunk size' if size == -1
        raise PayloadTooLarge, 'payload too large' if size == -2

        src.excess += line.bytesize + 2 - 16 - (2 * (size > HttpSyntax::CHUNK_EXCESS ? HttpSyntax::CHUNK_EXCESS : size))
        src.excess = 0 if src.excess.negative?
        raise BadRequest, 'chunk overhead too large' if src.excess > HttpSyntax::CHUNK_EXCESS

        if size.zero?
          err = read_trailers(sock, buf, deadline)
          raise_body(err) if err
          src.state = :done
          return true
        end
        src.chunk_left = size
        src.state = :data
        false
      end

      def chunk_end(src, sock, buf, deadline)
        err = read_exact(sock, buf, deadline, 2)
        raise_body(err) if err
        raise BadRequest, 'malformed chunk' unless buf.byte_at(0) == 13 && buf.byte_at(1) == 10

        buf.skip(2)
        src.state = :size
      end

      def raise_body(err)
        raise RequestTimeout, 'request body timeout' if err == :timeout
        raise PayloadTooLarge, 'payload too large' if err == :too_long
        raise TrailersTooLarge, 'trailers too large' if err == :too_big

        raise BadRequest, 'malformed request body'
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

      def read_trailers(sock, buf, deadline)
        bytes = 0
        loop do
          trailer, err = read_line(sock, buf, deadline, MAX_HEADER)
          return err if err
          return nil if trailer.empty?

          bytes += trailer.bytesize + 2
          return :too_big if bytes > MAX_HEADER

          name, sep, value = trailer.partition(':'.b)
          return :bad if sep.empty? || name.empty? || !name.match?(HttpSyntax::TOKEN)
          return :bad if HttpSyntax::FORBIDDEN_TRAILER.include?(name.downcase)
          return :bad if HttpSyntax.ctl?(HttpSyntax.trim_ows(value))
        end
      end

      def read_line(sock, buf, deadline, max)
        len = find_marker(sock, buf, deadline, CRLF, max, :bad)
        return [nil, len] if len.is_a?(Symbol)

        line = buf.take(len)
        buf.skip(CRLF.bytesize)
        [line, nil]
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
