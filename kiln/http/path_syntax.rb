module Kiln
  module HTTP
    module PathSyntax
      class << self
        def segments(path)
          text = path.to_s
          return :bad unless text.start_with?('/')
          return nil if text.include?('//') || (text != '/' && text.end_with?('/'))

          decode_all(text.split('/'))
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

        def decode_all(parts)
          out = []
          parts.each do |seg|
            next if seg.empty?

            decoded = decode(seg)
            return :bad if decoded.nil?

            out << decoded
          end
          out
        end

        def decode(seg)
          return utf8_or_binary(seg) unless seg.include?('%')

          out = unescape(seg.b)
          out && utf8_or_binary(out)
        end

        def unescape(raw)
          out = (+'').b
          index = 0
          size = raw.bytesize
          while index < size
            byte, step = decode_step(raw, index, size)
            return nil if byte.negative?

            out << byte
            index += step
          end
          out
        end

        def decode_step(raw, index, size)
          byte = raw.getbyte(index)
          return [byte, 1] unless byte == 37

          [escaped_byte(raw, index, size), 3]
        end

        def escaped_byte(raw, index, size)
          return -1 if index + 2 >= size

          hex = raw.byteslice(index + 1, 2)
          return -1 unless hex.match?(Syntax::PCT_HEX)

          byte = hex.to_i(16)
          byte.zero? ? -1 : byte
        end

        def utf8_or_binary(text)
          text.force_encoding(Encoding::UTF_8)
          text.valid_encoding? ? text : text.force_encoding(Encoding::ASCII_8BIT)
        end
      end
    end
  end
end
