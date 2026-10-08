module Kiln
  module PathSyntax
    class << self
      def segments(path)
        text = path.to_s
        return :bad unless text.start_with?("/")
        return nil if text.include?("//") || (text != "/" && text.end_with?("/"))
        parts = text.split("/")
        out = []
        i = 0
        limit = parts.size
        while i < limit
          seg = parts[i]
          i += 1
          next if seg.empty?
          decoded = decode(seg)
          return :bad if decoded.nil?
          out << decoded
        end
        out
      end

      def compile(path)
        path.split("/").reject(&:empty?)
      end

      def param_names(pattern)
        pattern.map { |seg| seg.start_with?(":") ? seg[1..] : "" }
      end

      def match?(pattern, names, segs)
        i = 0
        limit = pattern.size
        while i < limit
          return false unless !names[i].empty? || pattern[i] == segs[i]
          i += 1
        end
        true
      end

      def params(names, segs)
        out = {}
        i = 0
        limit = names.size
        while i < limit
          name = names[i]
          out[name] = segs[i] unless name.empty?
          i += 1
        end
        out
      end

      private

      def decode(seg)
        return utf8_or_binary(seg) unless seg.include?("%")
        raw = seg.b
        out = (+"").b
        i = 0
        size = raw.bytesize
        while i < size
          if raw.getbyte(i) == 37
            return nil if i + 2 >= size
            hex = raw.byteslice(i + 1, 2)
            return nil unless hex.match?(HttpSyntax::PCT_HEX)
            byte = hex.to_i(16)
            return nil if byte == 0
            out << byte
            i += 3
          else
            out << raw.getbyte(i)
            i += 1
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
