module Kiln
  module HTTP
    class Headers
      HOP = %w[content-length transfer-encoding connection].freeze
      TYPE_NAME = 'Content-Type'.freeze
      TYPE_KEY = 'content-type'.freeze
      TEXT_PLAIN = 'text/plain'.freeze
      JSON_TYPE = 'application/json'.freeze

      def initialize
        @items = []
        @date = false
      end

      LOWER = %w[Content-Type Content-Length Content-Encoding Content-Range Content-Disposition Cache-Control ETag
                 Last-Modified Location Vary Set-Cookie Accept-Ranges Access-Control-Allow-Origin
                 Access-Control-Allow-Credentials Access-Control-Allow-Methods Access-Control-Allow-Headers
                 Access-Control-Expose-Headers Access-Control-Max-Age X-Request-Id Allow Date Expires
                 X-Accel-Buffering].to_h { |name| [name.freeze, name.downcase.freeze] }.freeze
      CANONICAL = LOWER.keys.to_h { |name| [name, name] }.freeze

      def []=(name, value)
        text = name.to_s
        key = lower(text)
        delete_key(key)
        store(text, key, value.to_s)
      end

      def add(name, value)
        text = name.to_s
        store(text, lower(text), value.to_s)
      end

      def [](name) = lookup(lower(name.to_s))

      def lookup(key)
        index = 1
        while index < @items.size
          return @items[index + 1] if @items[index] == key

          index += 3
        end
        nil
      end

      def key?(name) = !self[name].nil?

      def delete(name) = delete_key(lower(name.to_s))

      def plain = write_type(TEXT_PLAIN)

      def json_type = write_type(JSON_TYPE)

      def each
        index = 0
        while index < @items.size
          yield @items[index].dup, @items[index + 2]
          index += 3
        end
      end

      def append_to(out)
        index = 0
        while index < @items.size
          name = @items[index]
          value = @items[index + 2]
          out << name << Response::FIELD_SEP << value << Response::CRLF if value.frozen? || !Native.ctl?(value)
          index += 3
        end
        out
      end

      def size = @items.size / 3
      def date? = @date

      def no_transform?
        index = 1
        while index < @items.size
          return true if @items[index] == 'cache-control' && @items[index + 1].downcase.include?('no-transform')

          index += 3
        end
        false
      end

      private

      def store(name, key, value)
        return unless Native.token?(name) && !HOP.include?(key) && !Native.ctl?(value)

        @items.push(owned_name(name))
        @items.push(key)
        @items.push(value.frozen? ? value : value.dup)
        @date = true if key == 'date'
      end

      def owned_name(text)
        return text if text.frozen?

        known = CANONICAL[text]
        known.nil? ? text.dup : known
      end

      def lower(text)
        known = LOWER[text]
        return known unless known.nil?

        text.downcase
      end

      def delete_key(key)
        index = @items.size - 2
        while index >= 1
          @items.slice!(index - 1, 3) if @items[index] == key
          index -= 3
        end
        @date = false if key == 'date'
      end

      def write_type(value)
        delete_key(TYPE_KEY)
        @items.push(TYPE_NAME)
        @items.push(TYPE_KEY)
        @items.push(value)
      end
    end
  end
end
