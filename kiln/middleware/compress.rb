module Kiln
  module Middleware
    class CompressError < StandardError; end

    module Gzip
      native_func :once, %i[string int], :string, 'kiln_gz_once'
      native_func :open_handle, [:int], :int, 'kiln_gz_open'
      native_func :push, %i[int string int], :string, 'kiln_gz_push'
      native_func :close_handle, [:int], :int, 'kiln_gz_close'
    end

    class GzipStream
      EMPTY = ''.b.freeze

      def initialize(out, level)
        @out = out
        @handle = Gzip.open_handle(level)
        raise CompressError, 'cannot start gzip' if @handle.zero?
      end

      def write(data)
        text = data.to_s
        return self if text.empty?

        emit(Gzip.push(@handle, text, 0))
      end

      def <<(data) = write(data)

      def flush
        emit(Gzip.push(@handle, EMPTY, 1))
        @out.flush
        self
      end

      def event(data, event: nil, id: nil, retry_ms: nil)
        write(HTTP::Stream.sse(data.to_s, event, id, retry_ms))
        flush
      end

      def comment(text = '')
        write(HTTP::Stream.comment(text))
        flush
      end

      def closed? = @out.closed?

      def finish_gzip
        emit(Gzip.push(@handle, EMPTY, 2))
      end

      def release
        handle = @handle
        @handle = 0
        Gzip.close_handle(handle) unless handle.zero?
      end

      private

      def emit(bytes)
        @out.write(bytes) unless bytes.empty?
        self
      end
    end

    class Compress
      EXACT_TYPES = %w[application/json application/javascript application/xml application/xhtml+xml
                       application/wasm image/svg+xml].freeze
      APPLICATION = 'application/'.freeze
      SUFFIXES = %w[+json +xml].freeze
      NOT_ENCODED = [204, 205, 206].freeze
      VARY_NAME = 'Vary'.freeze
      VARY_VALUE = 'Accept-Encoding'.freeze
      ENCODING_NAME = 'Content-Encoding'.freeze
      GZIP_VALUE = 'gzip'.freeze
      RANGES_NAME = 'Accept-Ranges'.freeze
      CONTENT_TYPE = 'content-type'.freeze
      CONTENT_ENCODING = 'content-encoding'.freeze
      CONTENT_RANGE = 'content-range'.freeze
      ETAG = 'etag'.freeze

      module Matching
        def compressible?(content_type)
          return false if content_type.nil?

          start, limit = media_bounds(content_type)
          return true if prefix?(content_type, start, limit, 'text/')
          return true if EXACT_TYPES.any? { |type| token_equal?(content_type, start, limit, type) }
          return false unless prefix?(content_type, start, limit, APPLICATION)

          SUFFIXES.any? { |suffix| suffix?(content_type, start, limit, suffix) }
        end

        def accepts_gzip?(value)
          !value.nil? && HTTP::Native.kiln_http_accepts_gzip(value, value.bytesize) == 1
        end

        def pipe(inner, out, level)
          gzip = GzipStream.new(out, level)
          begin
            inner.call(gzip)
            gzip.finish_gzip
          ensure
            gzip.release
          end
        end

        private

        def media_bounds(value)
          limit = value.index(';') || value.bytesize
          start = skip_ows(value, 0, limit)
          [start, trim_ows(value, start, limit)]
        end

        def prefix?(value, start, limit, token)
          limit - start >= token.bytesize && token_equal?(value, start, start + token.bytesize, token)
        end

        def suffix?(value, start, limit, token)
          limit - start >= token.bytesize && token_equal?(value, limit - token.bytesize, limit, token)
        end

        def skip_ows(value, index, limit)
          index += 1 while index < limit && [32, 9].include?(value.getbyte(index))
          index
        end

        def trim_ows(value, start, limit)
          limit -= 1 while limit > start && [32, 9].include?(value.getbyte(limit - 1))
          limit
        end

        def token_equal?(value, start, limit, token)
          return false unless limit - start == token.bytesize

          index = 0
          while index < token.bytesize
            byte = value.getbyte(start + index)
            byte += 32 if byte && byte >= 65 && byte <= 90
            return false unless byte == token.getbyte(index)

            index += 1
          end
          true
        end
      end

      extend Matching

      def initialize(nxt, level: 2, stream_level: 1, min_size: 1024)
        @next = nxt
        @level = Integer(level)
        @stream_level = Integer(stream_level)
        @min_size = Integer(min_size)
        raise ArgumentError, 'levels must be 1..9' unless @level.between?(1, 9) && @stream_level.between?(1, 9)
      end

      def call(ctx)
        @next.call(ctx)
        encode(ctx.req, ctx.res)
      end

      private

      def encode(req, res)
        headers = res.headers
        return unless eligible?(res, headers)

        res.status == 304 ? encode_fresh(req, res, headers) : encode_body(req, res, headers)
      end

      def encode_fresh(req, res, headers)
        size = res.noted_length
        return if size.nil? || size < @min_size

        headers.add(VARY_NAME, VARY_VALUE)
        return unless Compress.accepts_gzip?(req.headers['accept-encoding'])

        weaken(headers)
        reject_match(req, res)
      end

      def encode_body(req, res, headers)
        raw = res.streaming? ? nil : res.body.to_s
        return if raw && raw.bytesize < @min_size

        headers.add(VARY_NAME, VARY_VALUE)
        return unless gzip_wanted?(req)

        weaken(headers)
        return if reject_match(req, res)

        headers[ENCODING_NAME] = GZIP_VALUE
        raw ? res.body = Gzip.once(raw, @level) : wrap(res)
      end

      def gzip_wanted?(req)
        return false if req.headers['if-match'] && !HTTP::Conditional::SAFE.include?(req.verb)

        Compress.accepts_gzip?(req.headers['accept-encoding'])
      end

      def eligible?(res, headers)
        status = res.status
        return false unless status.is_a?(Integer) && status >= 200 && !NOT_ENCODED.include?(status)

        type = headers.lookup(CONTENT_TYPE)
        type = res.noted_type if type.nil? && status == 304
        Compress.compressible?(type) && untouched?(headers)
      end

      def untouched?(headers)
        return false if headers.lookup(CONTENT_ENCODING) || headers.lookup(CONTENT_RANGE)

        !headers.no_transform?
      end

      def weaken(headers)
        headers.delete(RANGES_NAME)
        etag = headers.lookup(ETAG)
        headers['ETag'] = "W/#{etag}" if etag && !etag.start_with?('W/')
      end

      def reject_match(req, res)
        return nil unless match_failed?(req, res.headers)

        res.status = 412
        res.body = ''
        res.unstream
        res
      end

      def match_failed?(req, headers)
        list = req.headers['if-match']
        return false if list.nil?

        text = list.strip
        return false if text == '*'

        etag = headers['ETag']
        return true if etag.nil? || etag.empty?

        !HTTP::Conditional.tag_listed?(text, etag, strong: true)
      end

      def wrap(res)
        inner = res.stream_body
        level = @stream_level
        res.stream(status: res.status) { |out| Compress.pipe(inner, out, level) }
      end
    end
  end
end
