module Kiln
  class BadRequest < StandardError; end
  class UnsupportedMediaType < StandardError; end

  module Media
    JSON_TYPE = 'application/json'.freeze
    JSON_PREFIX = 'application/'.freeze
    JSON_SUFFIX = '+json'.freeze
    FORM = 'application/x-www-form-urlencoded'.freeze
    UTF8 = 'utf-8'.freeze

    class << self
      def essence(value)
        return '' if value.nil?

        cut = value.index(';')
        (cut ? value[0, cut] : value).strip.downcase
      end

      def charset(value)
        return nil if value.nil?

        params = value.split(';')
        index = 1
        while index < params.size
          pair = params[index]
          index += 1
          eq = pair.index('=')
          next unless eq
          next unless pair[0, eq].strip.downcase == 'charset'

          return pair[eq + 1, pair.size - eq - 1].strip.delete('"').downcase
        end
        nil
      end

      def json?(value)
        type = essence(value)
        return false unless type == JSON_TYPE || (type.start_with?(JSON_PREFIX) && type.end_with?(JSON_SUFFIX))

        set = charset(value)
        set.nil? || set == UTF8
      end

      def form?(value) = essence(value) == FORM
    end
  end

  module Form
    class << self
      def decode(text)
        out = {}
        return out if text.nil? || text.empty?

        raw = text.b
        size = raw.bytesize
        start = 0
        while start < size
          stop = raw.index('&', start) || size
          store(out, raw.byteslice(start, stop - start)) if stop > start
          start = stop + 1
        end
        out
      end

      private

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
          byte = raw.getbyte(index)
          if byte == 43
            out << 32
            index += 1
          elsif byte == 37 && index + 2 < size && hex?(raw.getbyte(index + 1)) && hex?(raw.getbyte(index + 2))
            out << ((nibble(raw.getbyte(index + 1)) << 4) | nibble(raw.getbyte(index + 2)))
            index += 3
          else
            out << byte
            index += 1
          end
        end
        utf8(out)
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

  module Cookies
    SAME_SITE = %w[Strict Lax None].freeze

    class << self
      def parse(header)
        out = {}
        return out if header.nil? || header.empty?

        parts = header.split(';')
        index = 0
        while index < parts.size
          part = parts[index].strip
          index += 1
          eq = part.index('=')
          next if eq.nil? || eq.zero?

          name = part[0, eq].strip
          value = part[eq + 1, part.size - eq - 1].strip
          value = value[1, value.size - 2] if value.size >= 2 && value.start_with?('"') && value.end_with?('"')
          out[name] = value unless out.key?(name)
        end
        out
      end

      def serialize(name, value, path, domain, max_age, secure, http_only, same_site)
        raise ArgumentError, 'invalid cookie name' unless HttpNative.token?(name)
        raise ArgumentError, 'invalid cookie value' unless octets?(value)
        raise ArgumentError, 'invalid cookie path' unless attribute?(path)
        raise ArgumentError, 'invalid cookie domain' unless attribute?(domain)
        raise ArgumentError, 'invalid SameSite' unless same_site.nil? || SAME_SITE.include?(same_site)
        raise ArgumentError, 'SameSite=None requires secure' if same_site == 'None' && !secure

        out = "#{name}=#{value}"
        out << "; Path=#{path}" if path
        out << "; Domain=#{domain}" if domain
        out << "; Max-Age=#{max_age.to_i}" unless max_age.nil?
        out << '; Secure' if secure
        out << '; HttpOnly' if http_only
        out << "; SameSite=#{same_site}" if same_site
        out
      end

      private

      def octets?(value)
        index = 0
        size = value.bytesize
        while index < size
          byte = value.getbyte(index)
          index += 1
          next if byte == 0x21 || (byte >= 0x23 && byte <= 0x2B) || (byte >= 0x2D && byte <= 0x3A)
          next if (byte >= 0x3C && byte <= 0x5B) || (byte >= 0x5D && byte <= 0x7E)

          return false
        end
        true
      end

      def attribute?(value)
        return true if value.nil?

        !value.empty? && !value.include?(';') && !HttpNative.ctl?(value)
      end
    end
  end
end
