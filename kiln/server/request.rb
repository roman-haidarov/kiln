module Kiln
  class Server
    private

    def read_request(sock, buf, scan)
      if buf.empty?
        return nil if @draining
        status = wait_io(sock, buf, Kiln.now + @read_timeout)
        return nil unless status == :ok
      end
      deadline = Kiln.now + @request_timeout
      len = find_marker(sock, buf, deadline, HEADER_END, MAX_HEADER, :too_big)
      return HttpSyntax.error_tuple(len) if len.is_a?(Symbol)
      parsed = HttpNative.parse_at(buf.data, buf.pos, len, scan)
      buf.skip(len + HEADER_END.bytesize)
      return HttpSyntax.error_tuple(parsed) if parsed.is_a?(Symbol)
      version, verb, target, headers = parsed
      return HttpSyntax.error_tuple(:not_implemented, version: version) if verb == "CONNECT"
      if target == "*"
        return HttpSyntax.error_tuple(:bad, version: version) unless verb == "OPTIONS"
      elsif !target.start_with?("/") && !target.match?(HttpSyntax::ABSOLUTE_FORM)
        return HttpSyntax.error_tuple(:bad, version: version)
      end
      absolute = !target.start_with?("/") && target.match?(HttpSyntax::ABSOLUTE_FORM)
      host = headers["host"]
      if version == "1.1" && (host.nil? || (!absolute && host.empty?))
        return HttpSyntax.error_tuple(:bad, version: version)
      end
      return HttpSyntax.error_tuple(:bad, version: version) if host && !host.empty? && !HttpNative.host?(host)
      if absolute
        target, authority = HttpSyntax.absolute_target(target)
        return HttpSyntax.error_tuple(:bad, version: version) unless target
        headers["host"] = authority
      end
      if headers.key?("transfer-encoding")
        return HttpSyntax.error_tuple(:bad, version: version) if version == "1.0" || headers.key?("content-length")
      end
      expect = headers["expect"]
      if expect && !expect.empty? && expect.strip.downcase != "100-continue"
        return HttpSyntax.error_tuple(:expectation, version: version)
      end
      len = HttpSyntax.content_length(headers, @max_body)
      return HttpSyntax.error_tuple(len, version: version) if len.is_a?(Symbol)
      body, err = read_body(sock, buf, deadline, headers, len, version)
      return HttpSyntax.error_tuple(err, version: version) if err
      return HttpSyntax.error_tuple(:timeout, version: version) if Kiln.now > deadline
      [:req, Request.new(verb, target, headers, body, http_version: version), deadline]
    end

    def read_body(sock, buf, deadline, headers, len, version)
      if headers.key?("transfer-encoding")
        codings = headers["transfer-encoding"].split(",", -1).map { |coding| coding.strip.downcase }
        return [nil, :bad] if codings.any?(&:empty?) || codings.last != "chunked" || codings.count("chunked") > 1
        return [nil, :unsupported_te] if codings.size > 1
        maybe_continue(sock, headers, buf.empty?, version, buf)
        return read_chunked(sock, buf, deadline)
      end
      len ||= 0
      return [EMPTY_BODY, nil] if len == 0
      maybe_continue(sock, headers, buf.size < len, version, buf)
      err = read_exact(sock, buf, deadline, len)
      return [nil, err] if err
      [buf.take(len), nil]
    end

    def maybe_continue(sock, headers, pending, version, buf)
      return unless pending && version == "1.1"
      tokens = headers["expect"].to_s.split(",").map { |part| part.strip.downcase }
      return unless tokens.include?("100-continue")
      if buf.outbox && !flush_outbox(sock, buf.outbox, Kiln.now + 1.0)
        raise IOError, "pipelined responses could not be sent"
      end
      raise IOError, "100 Continue could not be sent" unless write_all(sock, CONTINUE, Kiln.now + 1.0)
    end

    def read_chunked(sock, buf, deadline)
      body = (+"").b
      excess = 0
      loop do
        line, err = read_line(sock, buf, deadline, 4096)
        return [nil, err] if err
        size = HttpNative.kiln_chunk_size(line, line.bytesize, @max_body - body.bytesize)
        return [nil, :bad] if size == -1
        return [nil, :too_long] if size == -2
        excess += line.bytesize + 2 - 16 - 2 * size
        excess = 0 if excess < 0
        return [nil, :bad] if excess > HttpSyntax::CHUNK_EXCESS
        return [nil, :too_long] if size > @max_body || body.bytesize + size > @max_body
        if size == 0
          err = read_trailers(sock, buf, deadline)
          return err ? [nil, err] : [body, nil]
        end
        err = read_exact(sock, buf, deadline, size + 2)
        return [nil, err] if err
        return [nil, :bad] unless buf.byte_at(size) == 13 && buf.byte_at(size + 1) == 10
        body << buf.take(size)
        buf.skip(2)
      end
    end

    def read_trailers(sock, buf, deadline)
      bytes = 0
      loop do
        trailer, err = read_line(sock, buf, deadline, MAX_HEADER)
        return err if err
        return nil if trailer.empty?
        bytes += trailer.bytesize + 2
        return :too_big if bytes > MAX_HEADER
        name, sep, value = trailer.partition(":".b)
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
      loop do
        i = buf.index(marker, from)
        if i
          return overflow if i > max
          return i
        end
        return overflow if buf.size > max + marker.bytesize
        from = buf.size - marker.bytesize + 1
        from = 0 if from < 0
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
          raise IOError, "pipelined responses could not be sent"
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
