module Kiln
  module HTTP
    class Request
      EMPTY_PARAMS = {}.freeze

      HTTPS = 'https'.freeze
      HTTP = 'http'.freeze
      NO_PROTOCOL = ''.freeze

      attr_reader :verb, :path, :query, :headers, :http_version
      attr_accessor :params

      class Wire
        attr_reader :http_version, :payload, :alpn

        def initialize(http_version, payload, alpn)
          @http_version = http_version
          @payload = payload
          @alpn = alpn
        end
      end

      def initialize(verb, target, headers, body, wire = nil)
        @verb = verb
        @headers = headers
        @body = body
        split_target(target.to_s)
        apply_wire(wire)
        @params = EMPTY_PARAMS
        @json_nesting = -1
      end

      def body
        payload = @payload
        return @body if payload.nil? || !payload.streamed? || payload.complete?

        @body = payload.read_all
      end

      def payload = @payload ||= Payload.buffered(@body.to_s, nil)

      def content_length
        payload = @payload
        return payload.length if payload&.streamed?

        @body.to_s.bytesize
      end

      def limit_body(limit)
        raise PayloadTooLarge, 'payload too large' if (content_length || 0) > limit

        @payload.limit = limit if streamed?
        self
      end

      def streamed? = !@payload.nil? && @payload.streamed?
      def tls? = !@alpn.nil?
      def scheme = @alpn.nil? ? HTTP : HTTPS
      def alpn = @alpn || NO_PROTOCOL

      def upgrade?
        upgrade = header('upgrade')
        return false if upgrade.nil? || upgrade.empty?

        Syntax.token_list?(header('connection'), 'upgrade')
      end

      def header(name) = @headers[name] || @headers[name.downcase]

      def query_params = @query_params ||= Form.decode(@query)

      def form
        return @form if @form

        unless Media.form?(header('content-type'))
          raise UnsupportedMediaType, 'expected application/x-www-form-urlencoded'
        end

        @form = Form.decode(body.to_s)
      end

      def json(max_nesting: Json::MAX_NESTING)
        parsed = @json_nesting
        return @json if parsed >= 0 && parsed <= max_nesting

        raise UnsupportedMediaType, 'expected application/json' unless Media.json?(header('content-type'))

        begin
          @json = Json.parse(body.to_s, max_nesting: max_nesting)
        rescue JsonError => e
          raise BadRequest, "invalid JSON: #{e.message}"
        end
        @json_nesting = max_nesting
        @json
      end

      def cookies = @cookies ||= Cookies.parse(header('cookie'))

      def cookie(name) = cookies[name]

      private

      def split_target(text)
        cut = Native.byteindex(text, '?', 0, 0)
        @path = cut >= 0 ? text.byteslice(0, cut) : text
        @query = cut >= 0 ? text.byteslice(cut + 1, text.bytesize - cut - 1) : ''
      end

      def apply_wire(wire)
        @payload = wire&.payload
        @http_version = wire&.http_version == '1.0' ? '1.0' : '1.1'
        @alpn = wire&.alpn
      end
    end
  end
end
