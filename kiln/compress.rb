module Kiln
  class CompressError < StandardError; end

  module Gzip
    native_func :once, %i[string int], :string, 'kiln_gz_once'
    native_func :open_handle, [:int], :int, 'kiln_gz_open'
    native_func :push, %i[int string int], :string, 'kiln_gz_push'
    native_func :close_handle, [:int], :int, 'kiln_gz_close'
  end

  class GzipStream
    EMPTY = ''.b.freeze
    FIELD_BREAK = /[\r\n]/

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
      write(Stream.sse(data.to_s, event, id, retry_ms))
      flush
    end

    def comment(text = '')
      raise ArgumentError, 'SSE comment cannot contain a line break' if FIELD_BREAK.match?(text)

      write(": #{text}\n\n")
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

    class << self
      def compressible?(content_type)
        return false if content_type.nil?

        cut = content_type.index(';')
        limit = cut || content_type.bytesize
        start = skip_ows(content_type, 0, limit)
        limit = trim_ows(content_type, start, limit)
        length = limit - start
        return true if length >= 5 && token_equal?(content_type, start, start + 5, 'text/')
        return true if EXACT_TYPES.any? { |type| token_equal?(content_type, start, limit, type) }
        return false unless length >= APPLICATION.bytesize &&
                            token_equal?(content_type, start, start + APPLICATION.bytesize, APPLICATION)

        SUFFIXES.any? do |suffix|
          length >= suffix.bytesize &&
            token_equal?(content_type, limit - suffix.bytesize, limit, suffix)
        end
      end

      def accepts_gzip?(value)
        !value.nil? && HttpNative.kiln_http_accepts_gzip(value, value.bytesize) == 1
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

      def skip_ows(value, index, limit)
        index += 1 while index < limit && (value.getbyte(index) == 32 || value.getbyte(index) == 9)
        index
      end

      def trim_ows(value, start, limit)
        limit -= 1 while limit > start && (value.getbyte(limit - 1) == 32 || value.getbyte(limit - 1) == 9)
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
      streaming = res.streaming?
      raw = nil
      unless streaming
        raw = res.body.to_s
        return if raw.bytesize < @min_size
      end
      if req.headers['if-match'] && !Conditional::SAFE.include?(req.verb)
        return headers.add(VARY_NAME, VARY_VALUE)
      end
      return headers.add(VARY_NAME, VARY_VALUE) unless Compress.accepts_gzip?(req.headers['accept-encoding'])

      raw = Gzip.once(raw, @level) unless streaming
      headers.add(VARY_NAME, VARY_VALUE)
      weaken(headers)
      return if reject_match(req, res)

      headers[ENCODING_NAME] = GZIP_VALUE
      streaming ? wrap(res) : res.body = raw
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

      !Conditional.tag_listed?(text, etag, strong: true)
    end

    def wrap(res)
      inner = res.stream_body
      level = @stream_level
      res.stream(status: res.status) { |out| Compress.pipe(inner, out, level) }
    end
  end
end
