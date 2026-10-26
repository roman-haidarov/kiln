module Kiln
  module HTTP
    module Form
      class << self
        def decode(text)
          out = {}
          return out if text.nil? || text.empty?

          store_pairs(out, text.b)
          out
        end

        private

        def store_pairs(out, raw)
          size = raw.bytesize
          start = 0
          while start < size
            stop = raw.index('&', start) || size
            store(out, raw.byteslice(start, stop - start)) if stop > start
            start = stop + 1
          end
        end

        def store(out, pair)
          eq = pair.index('=')
          if eq
            out[component(pair.byteslice(0, eq))] = component(pair.byteslice(eq + 1, pair.bytesize - eq - 1))
          else
            out[component(pair)] = ''
          end
        end

        def component(raw)
          return utf8(raw.dup) unless raw.include?('%') || raw.include?('+')

          out = (+'').b
          index = 0
          size = raw.bytesize
          while index < size
            byte, step = unescape_at(raw, index, size)
            out << byte
            index += step
          end
          utf8(out)
        end

        def unescape_at(raw, index, size)
          byte = raw.getbyte(index)
          return [32, 1] if byte == 43
          return [byte, 1] unless byte == 37 && escape_at?(raw, index, size)

          [(nibble(raw.getbyte(index + 1)) << 4) | nibble(raw.getbyte(index + 2)), 3]
        end

        def escape_at?(raw, index, size)
          index + 2 < size && hex?(raw.getbyte(index + 1)) && hex?(raw.getbyte(index + 2))
        end

        def hex?(byte) = (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 70) || (byte >= 97 && byte <= 102)

        def nibble(byte)
          return byte - 48 if byte <= 57
          return byte - 55 if byte <= 70

          byte - 87
        end

        def utf8(text)
          text.force_encoding(Encoding::UTF_8)
          raise BadRequest, 'form data is not valid UTF-8' unless text.valid_encoding?

          text
        end
      end
    end
  end
end
