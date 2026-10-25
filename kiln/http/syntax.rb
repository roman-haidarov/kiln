module Kiln
  module HTTP
    module SyntaxHead
      def parse_head(head)
        lines = head.b.split(Syntax::CRLF)
        return :bad if lines.empty?

        line = request_line(lines.shift)
        return line if line.is_a?(Symbol)
        return :too_big if lines.size > Syntax::MAX_HEADERS

        headers = parse_fields(lines)
        return headers if headers.is_a?(Symbol)

        [line[0], line[1], line[2], headers]
      end

      private

      def request_line(first)
        match = first.match(Syntax::REQ_LINE)
        return :bad unless match

        verb = encode_owned(match[1])
        target = encode_owned(match[2])
        version = encode_owned(match[3])
        return :bad unless ['1.0', '1.1'].include?(version) && !ctl?(target)

        [version, verb, target]
      end

      def parse_fields(lines)
        headers = {}
        index = 0
        while index < lines.size
          return :bad unless add_field?(headers, lines[index])

          index += 1
        end
        headers
      end

      def add_field?(headers, line)
        return false if line.empty? || [32, 9].include?(line.getbyte(0))

        name, sep, value = line.partition(':'.b)
        return false if sep.empty? || name.empty? || !name.match?(Syntax::TOKEN)

        value = encode_owned(trim_ows(value))
        return false if ctl?(value)

        store_field?(headers, name.downcase.force_encoding(Encoding::UTF_8), value)
      end

      def store_field?(headers, key, value)
        unless headers.key?(key)
          headers[key] = value
          return true
        end
        return false if Syntax::SINGLE.include?(key)

        headers[key] = encode_owned(join_header(headers[key], value, key))
        true
      end

      def encode_owned(text)
        text.force_encoding(Encoding::UTF_8)
        text.valid_encoding? ? text : text.force_encoding(Encoding::ASCII_8BIT)
      end

      def join_header(left, right, key)
        out = left.b
        out << (key == 'cookie' ? '; '.b : ', '.b)
        out << right.b
        out
      end
    end

    module Syntax
      CRLF = "\r\n".b.freeze
      TOKEN = /\A[A-Za-z0-9!#$%&'*+.^_`|~-]+\z/n
      REQ_LINE = %r{\A([A-Za-z0-9!#$%&'*+.^_`|~-]+) ([^ \t]+) HTTP/(\d+\.\d+)\z}n
      CL_NUM = /\A(?:0|[1-9]\d*)\z/n
      PCT_HEX = /\A[0-9A-Fa-f]{2}\z/n
      HOST = /
        \A(?:
          \[(?:[0-9A-Fa-f:.%]+|[vV][0-9A-Fa-f]+\.[A-Za-z0-9._~!$&'()*+,;=:-]+)\]
          |[A-Za-z0-9._~!$&'()*+,;=%-]+
        )(?::[0-9]+)?\z
      /nx
      ABSOLUTE_FORM = %r{\Ahttps?://}in
      SINGLE = %w[content-length host transfer-encoding].freeze
      CTL = /[\x00-\x1f\x7f]/n

      ERRORS = {
        too_big: [431, 'headers too large'].freeze,
        timeout: [408, 'request timeout'].freeze,
        too_long: [413, 'payload too large'].freeze,
        unsupported_te: [501, 'not implemented'].freeze,
        expectation: [417, 'expectation failed'].freeze,
        not_implemented: [501, 'not implemented'].freeze
      }.freeze

      BAD_REQUEST = [400, 'bad request'].freeze
      MAX_HEADERS = 100
      MAX_LENGTH = 999_999_999_999_999_999

      extend SyntaxHead

      class << self
        def content_length(headers, max_body)
          raw = headers['content-length']
          return nil if raw.nil?

          text = raw.b
          return :bad unless Native.digits?(text)

          bound = max_body.to_s
          text_size = text.bytesize
          bound_size = bound.bytesize
          return :too_long if text_size > bound_size || (text_size == bound_size && (text <=> bound).positive?)

          text.to_i
        end

        def valid_host?(host)
          return false unless host.match?(HOST)

          mark = host.index('%')
          while mark
            pair = host.byteslice(mark + 1, 2)
            return false unless pair&.match?(PCT_HEX)

            mark = host.index('%', mark + 3)
          end
          true
        end

        def absolute_target(target)
          _scheme, rest = target.split('://', 2)
          return [nil, nil] if rest.nil? || rest.include?('#')

          stop = authority_end(rest)
          authority = rest.byteslice(0, stop)
          return [nil, nil] if authority.empty? || !valid_host?(authority)

          [origin_path(rest.byteslice(stop, rest.bytesize - stop).to_s), authority]
        end

        def persistent?(version, connection)
          return version == '1.1' if connection.nil?

          tokens = connection.to_s.split(',').map { |part| part.strip.downcase }
          return false if tokens.include?('close')

          version == '1.0' ? tokens.include?('keep-alive') : true
        end

        def token_list?(value, token)
          return false if value.nil?

          value.to_s.split(',').any? { |part| part.strip.casecmp?(token) }
        end

        def error_tuple(kind, version: '1.1')
          status, message = ERRORS.fetch(kind) { BAD_REQUEST }
          [:error, status, message, version]
        end

        def ctl?(text) = text.match?(CTL)

        def trim_ows(value)
          text = value.b
          text.sub!(/\A[ \t]+/n, '')
          text.sub!(/[ \t]+\z/n, '')
          text
        end

        private

        def authority_end(rest)
          stop = rest.bytesize
          slash = rest.index('/')
          query = rest.index('?')
          stop = slash if slash && slash < stop
          stop = query if query && query < stop
          stop
        end

        def origin_path(path) = path.empty? || path.start_with?('?') ? "/#{path}" : path
      end
    end
  end
end
