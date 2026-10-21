module Kiln
  module HTTP
    class Payload
      CHUNK = 64 * 1024
      EMPTY = ''.b.freeze

      attr_reader :length, :limit, :received, :source

      def initialize(source, length, limit, data = EMPTY)
        @source = source
        @data = data
        @length = length
        @limit = limit
        @received = 0
        @done = false
        @failure = nil
      end

      def limit=(value)
        unless value.nil? || (value.is_a?(Integer) && value >= 0)
          raise ArgumentError,
                'limit must be a non-negative Integer or nil'
        end

        @limit = value
      end

      def streamed? = !@source.nil?
      def complete? = @done
      def failed? = !@failure.nil?
      def too_large? = !@length.nil? && !@limit.nil? && @length > @limit

      def read(max = CHUNK)
        return nil if @done

        check_readable
        return (+'').b unless max.positive?

        chunk = @source ? pull(max) : slice(max)
        return finish_read if chunk.nil?

        @received += chunk.bytesize
        over(chunk)
      end

      def each
        while (chunk = read)
          yield chunk
        end
        self
      end

      def read_all
        if @source.nil? && @received.zero? && !@done && fits?(@data.bytesize)
          @received = @data.bytesize
          @done = true
          return @data
        end

        out = (+'').b
        each { |chunk| out << chunk }
        out
      end

      def discard
        @limit = nil
        each { |_chunk| nil }
        self
      end

      def remaining = @length.nil? ? nil : @length - @received

      class << self
        def buffered(data, limit) = Payload.new(nil, data.bytesize, limit, data)
      end

      private

      def check_readable
        failure = @failure
        raise failure if failure
        raise PayloadTooLarge, 'payload too large' if too_large?
      end

      def finish_read
        @done = true
        nil
      end

      def fits?(size) = @limit.nil? || size <= @limit

      def over(chunk)
        limit = @limit
        return chunk if limit.nil? || @received <= limit

        failure = PayloadTooLarge.new('payload too large')
        @failure = failure
        raise failure
      end

      def pull(max)
        @source.pull(max)
      rescue PayloadTooLarge, RequestTimeout, TrailersTooLarge, BadRequest, Runtime::ClientGone,
             Runtime::DeadlineExceeded => e
        @failure = e
        raise
      end

      def slice(max)
        size = @data.bytesize
        return nil if @received >= size

        take = size - @received
        take = max if take > max
        @data.byteslice(@received, take)
      end
    end
  end
end
