module Kiln
  module HTTP
    class ReadBuffer
      COMPACT_AT = 64 * 1024

      attr_reader :data, :pos
      attr_accessor :outbox

      def initialize
        @data = (+'').b
        @pos = 0
      end

      def size = @data.bytesize - @pos
      def empty? = @pos >= @data.bytesize

      def index(marker, from = 0)
        at = @data.byteindex(marker, @pos + from)
        at ? at - @pos : nil
      end

      def byte_at(offset) = @data.getbyte(@pos + offset)

      def take(len)
        out = @data.byteslice(@pos, len)
        skip(len)
        out
      end

      def skip(len)
        @pos += len
        size = @data.bytesize
        if @pos >= size
          @data = (+'').b
          @pos = 0
        elsif @pos >= COMPACT_AT
          @data = @data.byteslice(@pos, size - @pos)
          @pos = 0
        end
      end

      def append(chunk)
        if empty?
          @data = chunk
          @pos = 0
        else
          @data << chunk
        end
      end
    end
  end
end
