module Kiln
  module HTTP
    module Cookies
      SAME_SITE = %w[Strict Lax None].freeze
      KEYS = %i[path domain max_age secure http_only same_site].freeze

      class Cookie
        attr_reader :name, :value, :path, :domain, :max_age, :secure, :http_only, :same_site

        def initialize(name, value, attributes)
          @name = name
          @value = value
          @path = attributes.fetch(:path) { '/' }
          @domain = attributes[:domain]
          @max_age = attributes[:max_age]
          @secure = attributes.fetch(:secure, false)
          @http_only = attributes.fetch(:http_only, true)
          @same_site = attributes.fetch(:same_site) { 'Lax' }
        end
      end

      class << self
        def parse(header)
          out = {}
          return out if header.nil? || header.empty?

          header.split(';').each { |part| add_pair(out, part.strip) }
          out
        end

        def build(name, value, attributes)
          unknown = attributes.keys - KEYS
          raise ArgumentError, "unknown cookie attribute #{unknown.first}" unless unknown.empty?

          Cookie.new(name, value, attributes)
        end

        def serialize(cookie)
          validate(cookie)
          "#{cookie.name}=#{cookie.value}#{scope_part(cookie)}#{flag_part(cookie)}"
        end

        private

        def add_pair(out, part)
          eq = part.index('=')
          return if eq.nil? || eq.zero?

          name = part[0, eq].strip
          out[name] = unquote(part[eq + 1, part.size - eq - 1].strip) unless out.key?(name)
        end

        def unquote(value)
          return value unless value.size >= 2 && value.start_with?('"') && value.end_with?('"')

          value[1, value.size - 2]
        end

        def validate(cookie)
          raise ArgumentError, 'invalid cookie name' unless Native.token?(cookie.name)
          raise ArgumentError, 'invalid cookie value' unless octets?(cookie.value)
          raise ArgumentError, 'invalid cookie path' unless attribute?(cookie.path)
          raise ArgumentError, 'invalid cookie domain' unless attribute?(cookie.domain)

          validate_same_site(cookie.same_site, cookie.secure)
        end

        def validate_same_site(same_site, secure)
          raise ArgumentError, 'invalid SameSite' unless same_site.nil? || SAME_SITE.include?(same_site)
          raise ArgumentError, 'SameSite=None requires secure' if same_site == 'None' && !secure
        end

        def scope_part(cookie)
          out = +''
          out << "; Path=#{cookie.path}" if cookie.path
          out << "; Domain=#{cookie.domain}" if cookie.domain
          out << "; Max-Age=#{cookie.max_age.to_i}" unless cookie.max_age.nil?
          out
        end

        def flag_part(cookie)
          out = +''
          out << '; Secure' if cookie.secure
          out << '; HttpOnly' if cookie.http_only
          out << "; SameSite=#{cookie.same_site}" if cookie.same_site
          out
        end

        def octets?(value)
          index = 0
          size = value.bytesize
          while index < size
            return false unless octet?(value.getbyte(index))

            index += 1
          end
          true
        end

        def octet?(byte)
          byte == 0x21 || (byte >= 0x23 && byte <= 0x2B) || (byte >= 0x2D && byte <= 0x3A) ||
            (byte >= 0x3C && byte <= 0x5B) || (byte >= 0x5D && byte <= 0x7E)
        end

        def attribute?(value)
          return true if value.nil?

          !value.empty? && !value.include?(';') && !Native.ctl?(value)
        end
      end
    end
  end
end
