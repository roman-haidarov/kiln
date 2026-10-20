module Kiln
  class PayloadTooLarge < StandardError; end
  class RequestTimeout < StandardError; end
  class TrailersTooLarge < StandardError; end

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
      raise ArgumentError,
            'limit must be a non-negative Integer or nil' unless value.nil? || (value.is_a?(Integer) && value >= 0)

      @limit = value
    end

    def streamed? = !@source.nil?
    def complete? = @done
    def failed? = !@failure.nil?
    def too_large? = !@length.nil? && !@limit.nil? && @length > @limit

    def read(max = CHUNK)
      return nil if @done

      failure = @failure
      raise failure if failure
      raise PayloadTooLarge, 'payload too large' if too_large?

      chunk = @source ? pull(max) : slice(max)
      if chunk.nil?
        @done = true
        return nil
      end
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
    rescue PayloadTooLarge, RequestTimeout, TrailersTooLarge, BadRequest, ClientGone, DeadlineExceeded => e
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
