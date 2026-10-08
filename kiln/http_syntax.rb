module Kiln
  module HttpSyntax
    CRLF = "\r\n".b.freeze
    TOKEN = /\A[A-Za-z0-9!#$%&'*+.^_`|~-]+\z/n
    REQ_LINE = /\A([A-Za-z0-9!#$%&'*+.^_`|~-]+) ([^ \t]+) HTTP\/(\d+\.\d+)\z/n
    CL_NUM = /\A(?:0|[1-9]\d*)\z/n
    PCT_HEX = /\A[0-9A-Fa-f]{2}\z/n
    HOST = /\A(?:\[(?:[0-9A-Fa-f:.%]+|[vV][0-9A-Fa-f]+\.[A-Za-z0-9._~!$&'()*+,;=:-]+)\]|[A-Za-z0-9._~!$&'()*+,;=%-]+)(?::[0-9]+)?\z/n
    ABSOLUTE_FORM = /\Ahttps?:\/\//in
    SINGLE = %w[content-length host transfer-encoding].freeze
    FORBIDDEN_TRAILER = %w[content-length transfer-encoding host connection trailer te upgrade].freeze
    CTL = /[\x00-\x1f\x7f]/n

    ERRORS = {
      too_big: [431, "headers too large"].freeze,
      timeout: [408, "request timeout"].freeze,
      too_long: [413, "payload too large"].freeze,
      unsupported_te: [501, "not implemented"].freeze,
      expectation: [417, "expectation failed"].freeze,
      not_implemented: [501, "not implemented"].freeze
    }.freeze

    BAD_REQUEST = [400, "bad request"].freeze
    MAX_HEADERS = 100
    CHUNK_EXCESS = 16 * 1024

    class << self
      def parse_head(head)
        lines = head.b.split(CRLF)
        return :bad if lines.empty?
        match = lines.shift.match(REQ_LINE)
        return :bad unless match
        verb = encode_owned(match[1])
        target = encode_owned(match[2])
        version = encode_owned(match[3])
        return :bad unless version == "1.0" || version == "1.1"
        return :bad if ctl?(target)
        return :too_big if lines.size > MAX_HEADERS
        headers = {}
        lines.each do |line|
          return :bad if line.empty?
          lead = line.getbyte(0)
          return :bad if lead == 32 || lead == 9
          name, sep, value = line.partition(":".b)
          return :bad if sep.empty? || name.empty? || !name.match?(TOKEN)
          value = encode_owned(trim_ows(value))
          return :bad if ctl?(value)
          key = name.downcase.force_encoding(Encoding::UTF_8)
          if headers.key?(key)
            return :bad if SINGLE.include?(key)
            headers[key] = encode_owned(join_header(headers[key], value))
          else
            headers[key] = value
          end
        end
        [version, verb, target, headers]
      end

      def content_length(headers, max_body)
        raw = headers["content-length"]
        return nil if raw.nil?
        text = raw.b
        return :bad unless HttpNative.digits?(text)
        bound = max_body.to_s
        return :too_long if text.bytesize > bound.bytesize || (text.bytesize == bound.bytesize && (text <=> bound) > 0)
        text.to_i
      end

      def valid_host?(host)
        return false unless host.match?(HOST)
        mark = host.index("%")
        while mark
          pair = host.byteslice(mark + 1, 2)
          return false unless pair && pair.match?(PCT_HEX)
          mark = host.index("%", mark + 3)
        end
        true
      end

      def absolute_target(target)
        _scheme, rest = target.split("://", 2)
        return [nil, nil] if rest.nil? || rest.include?("#")
        stop = rest.bytesize
        slash = rest.index("/")
        query = rest.index("?")
        stop = slash if slash && slash < stop
        stop = query if query && query < stop
        authority = rest.byteslice(0, stop)
        return [nil, nil] if authority.empty? || !valid_host?(authority)
        path = rest.byteslice(stop, rest.bytesize - stop).to_s
        path = "/#{path}" if path.empty? || path.start_with?("?")
        [path, authority]
      end

      def persistent?(version, connection)
        return version == "1.1" if connection.nil?
        tokens = connection.to_s.split(",").map { |part| part.strip.downcase }
        return false if tokens.include?("close")
        version == "1.0" ? tokens.include?("keep-alive") : true
      end

      def error_tuple(kind, version: "1.1")
        status, message = ERRORS.fetch(kind, BAD_REQUEST)
        [:error, status, message, version]
      end

      def ctl?(text) = text.match?(CTL)

      def trim_ows(value)
        text = value.b
        text.sub!(/\A[ \t]+/n, "")
        text.sub!(/[ \t]+\z/n, "")
        text
      end

      private

      def encode_owned(text)
        text.force_encoding(Encoding::UTF_8)
        text.valid_encoding? ? text : text.force_encoding(Encoding::ASCII_8BIT)
      end

      def join_header(left, right)
        out = left.b
        out << ", ".b
        out << right.b
        out
      end
    end
  end
end
