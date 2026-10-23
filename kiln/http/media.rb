module Kiln
  module HTTP
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
            found = charset_param(params[index])
            return found if found

            index += 1
          end
          nil
        end

        def charset_param(pair)
          eq = pair.index('=')
          return nil unless eq && pair[0, eq].strip.downcase == 'charset'

          pair[eq + 1, pair.size - eq - 1].strip.delete('"').downcase
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
  end
end
