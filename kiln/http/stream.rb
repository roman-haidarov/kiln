module Kiln
  module HTTP
    class Stream
      FLUSH_AT = 16 * 1024
      CRLF = "\r\n".b.freeze
      TERMINATOR = "0\r\n\r\n".b.freeze
      TRAILING_TERMINATOR = "\r\n0\r\n\r\n".b.freeze
      EMPTY = ''.b.freeze
      LINE_BREAK = /\r\n|\r|\n/
      FIELD_BREAK = /[\r\n]/

      attr_reader :written

      def initialize(push, closed, chunked, limit = nil)
        @push = push
        @closed = closed
        @chunked = chunked
        @limit = limit
        @written = 0
        @buffer = (+'').b
        @sent = false
      end

      def write(data)
        text = data.to_s
        return self if text.empty?

        return send_now(text) if text.bytesize >= FLUSH_AT

        @buffer << text
        flush if @buffer.bytesize >= FLUSH_AT
        self
      end

      def <<(data) = write(data)

      def flush
        return self if @buffer.empty?

        data = @buffer
        @buffer = (+'').b
        deliver(data)
      end

      def verify!
        limit = @limit
        return self if limit.nil? || @written == limit

        raise ArgumentError, "stream wrote #{@written} of #{limit} bytes"
      end

      def ending
        return EMPTY unless @chunked

        @sent ? TRAILING_TERMINATOR : TERMINATOR
      end

      def event(data, event: nil, id: nil, retry_ms: nil)
        write(Stream.sse(data.to_s, event, id, retry_ms))
        flush
      end

      def comment(text = '')
        write(Stream.comment(text))
        flush
      end

      def closed? = @closed.call == true

      class << self
        def comment(text)
          raise ArgumentError, 'SSE comment cannot contain a line break' if FIELD_BREAK.match?(text)

          ": #{text}\n\n"
        end

        def chunk_head(size, carry)
          out = carry ? CRLF.dup : (+'').b
          out << size.to_s(16) << CRLF
        end

        def sse(data, event, id, retry_ms)
          out = field('event', event) + field('id', id)
          out << "retry: #{Integer(retry_ms)}\n" unless retry_ms.nil?
          data.split(LINE_BREAK, -1).each { |line| out << 'data: ' << line << "\n" }
          out << "data: \n" if data.empty?
          out << "\n"
        end

        private

        def field(name, value)
          return +'' if value.nil?

          text = value.to_s
          raise ArgumentError, "SSE #{name} cannot contain a line break" if FIELD_BREAK.match?(text)

          "#{name}: #{text}\n"
        end
      end

      private

      def send_now(bytes)
        flush
        deliver(bytes)
      end

      def deliver(data)
        size = data.bytesize
        limit = @limit
        raise ArgumentError, "stream wrote more than its #{limit} bytes" if limit && @written + size > limit

        @written += size
        prefix = @chunked ? Stream.chunk_head(size, @sent) : EMPTY
        @sent = true
        @push.call(prefix, data)
        self
      end
    end
  end
end
