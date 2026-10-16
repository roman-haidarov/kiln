module Kiln
  module PathSyntax
    class << self
      def segments(path)
        text = path.to_s
        return :bad unless text.start_with?('/')
        return nil if text.include?('//') || (text != '/' && text.end_with?('/'))

        parts = text.split('/')
        out = []
        index = 0
        limit = parts.size
        while index < limit
          seg = parts[index]
          index += 1
          next if seg.empty?

          decoded = decode(seg)
          return :bad if decoded.nil?

          out << decoded
        end
        out
      end

      def compile(path)
        path.split('/').reject(&:empty?)
      end

      def param_names(pattern)
        pattern.map { |seg| seg.start_with?(':') ? seg[1..] : '' }
      end

      def params(names, segs)
        out = {}
        index = 0
        limit = names.size
        while index < limit
          name = names[index]
          out[name] = segs[index] unless name.empty?
          index += 1
        end
        out
      end

      private

      def decode(seg)
        return utf8_or_binary(seg) unless seg.include?('%')

        raw = seg.b
        out = (+'').b
        index = 0
        size = raw.bytesize
        while index < size
          byte_at = raw.getbyte(index)
          if byte_at == 37
            return nil if index + 2 >= size

            hex = raw.byteslice(index + 1, 2)
            return nil unless hex.match?(HttpSyntax::PCT_HEX)

            byte = hex.to_i(16)
            return nil if byte.zero?

            out << byte
            index += 3
          else
            out << byte_at
            index += 1
          end
        end
        utf8_or_binary(out)
      end

      def utf8_or_binary(text)
        text.force_encoding(Encoding::UTF_8)
        text.valid_encoding? ? text : text.force_encoding(Encoding::ASCII_8BIT)
      end
    end
  end
end
