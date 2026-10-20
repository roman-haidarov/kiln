module Kiln
  module HttpDate
    FORMAT = '%a, %d %b %Y %H:%M:%S GMT'

    class << self
      def value = current.dup

      def append(out) = out << current

      private

      def current
        sec = Process.clock_gettime(Process::CLOCK_REALTIME, :second)
        cached = @cached
        return cached[1] if cached && cached[0] == sec

        text = Time.now.utc.strftime(FORMAT).b
        @cached = [sec, text]
        text
      end
    end
  end

  class Request
    EMPTY_PARAMS = {}.freeze

    HTTPS = 'https'.freeze
    HTTP = 'http'.freeze
    NO_PROTOCOL = ''.freeze

    attr_reader :verb, :path, :query, :headers, :http_version
    attr_accessor :params

    def initialize(verb, target, headers, body, http_version: '1.1', payload: nil, scheme: HTTP, alpn: NO_PROTOCOL)
      @verb = verb
      text = target.to_s
      cut = text.byteindex('?')
      @path = cut ? text.byteslice(0, cut) : text
      @query = cut ? text.byteslice(cut + 1, text.bytesize - cut - 1) : ''
      @headers = headers
      @body = body
      @payload = payload
      @http_version = http_version == '1.0' ? '1.0' : '1.1'
      @params = EMPTY_PARAMS
      @alpn = scheme == HTTPS ? alpn : nil
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

      HttpSyntax.token_list?(header('connection'), 'upgrade')
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
      return @json if parsed >= 0 && max_nesting >= parsed

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
  end

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

    def [](name)
      key = lower(name.to_s)
      lookup(key)
    end

    def lookup(key)
      index = 1
      while index < @items.size
        return @items[index + 1] if @items[index] == key

        index += 3
      end
      nil
    end

    def key?(name) = !self[name].nil?

    def delete(name)
      delete_key(lower(name.to_s))
    end

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
        out << name << Response::FIELD_SEP << value << Response::CRLF if value.frozen? || !HttpNative.ctl?(value)
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
      return unless HttpNative.token?(name)
      return if HOP.include?(key)
      return if HttpNative.ctl?(value)

      stored_name = owned_name(name)
      @items.push(stored_name)
      @items.push(key)
      stored_value = value.frozen? ? value : value.dup
      @items.push(stored_value)
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

  class Response
    REASONS = {
      200 => 'OK', 201 => 'Created', 204 => 'No Content',
      301 => 'Moved Permanently', 302 => 'Found', 304 => 'Not Modified',
      400 => 'Bad Request', 401 => 'Unauthorized', 403 => 'Forbidden',
      404 => 'Not Found', 405 => 'Method Not Allowed', 408 => 'Request Timeout', 417 => 'Expectation Failed',
      413 => 'Payload Too Large', 415 => 'Unsupported Media Type',
      431 => 'Request Header Fields Too Large',
      500 => 'Internal Server Error', 501 => 'Not Implemented', 503 => 'Service Unavailable',
      504 => 'Gateway Timeout'
    }.freeze
    HTTP_10 = '1.0'.freeze
    CRLF = "\r\n".b.freeze
    FIELD_SEP = ': '.b.freeze
    PREFIX_11 = 'HTTP/1.1 '.b.freeze
    PREFIX_10 = 'HTTP/1.0 '.b.freeze
    UNKNOWN_REASON = " Status\r\n".b.freeze
    LENGTH_PREFIX = 'Content-Length: '.b.freeze
    LENGTH_ZERO = "Content-Length: 0\r\n".b.freeze
    CHUNKED = "Transfer-Encoding: chunked\r\n".b.freeze
    EVENT_STREAM = 'text/event-stream; charset=utf-8'.freeze
    DATE_PREFIX = 'Date: '.b.freeze
    KEEP_ALIVE = "Connection: keep-alive\r\n".b.freeze
    CLOSE = "Connection: close\r\n".b.freeze
    LENGTHS = Array.new(4097) { |length| length.to_s.b.freeze }.freeze
    STATUS_11 = {}
    STATUS_10 = {}
    REASONS.each do |code, reason|
      STATUS_11[code] = "HTTP/1.1 #{code} #{reason}\r\n".b.freeze
      STATUS_10[code] = "HTTP/1.0 #{code} #{reason}\r\n".b.freeze
    end
    STATUS_11.freeze
    STATUS_10.freeze
    SWITCHING = 101
    UPGRADE_LINE = "HTTP/1.1 101 Switching Protocols\r\n".b.freeze
    CONNECTION_UPGRADE = "Connection: Upgrade\r\n".b.freeze
    UPGRADE_PREFIX = 'Upgrade: '.b.freeze

    attr_accessor :status, :body
    attr_reader :headers, :stream_body, :stream_length, :noted_length, :noted_type

    class Upgrade
      attr_reader :tunnel_protocol, :tunnel_proc

      def initialize(protocol, body)
        @tunnel_protocol = protocol
        @tunnel_proc = body
      end
    end

    def initialize
      @status = 200
      @headers = Headers.new
      @body = ''
      @stream_body = nil
      @stream_length = nil
      @noted_length = nil
      @noted_type = nil
      @tunnel = nil
    end

    def upgrade(protocol, &body)
      raise ArgumentError, 'upgrade needs a block' unless body
      raise ArgumentError, 'upgrade protocol must be a token' unless HttpNative.token?(protocol.to_s)

      @status = SWITCHING
      @body = ''
      @stream_body = nil
      @tunnel = Upgrade.new(protocol.to_s, body)
    end

    def hijack(&body)
      raise ArgumentError, 'hijack needs a block' unless body

      @status = SWITCHING
      @body = ''
      @stream_body = nil
      @tunnel = Upgrade.new('', body)
    end

    def websocket(ctx, protocols: [], max_message: WebSocket::MAX_MESSAGE, ping_interval: nil, &body)
      raise ArgumentError, 'websocket needs a block' unless body

      WebSocket.accept(ctx, protocols, max_message, ping_interval, body)
    end

    def tunnel? = !@tunnel.nil?
    def hijack? = tunnel? && protocol.empty?

    def tunnel_body
      tunnel = @tunnel
      tunnel&.tunnel_proc
    end

    def protocol
      tunnel = @tunnel
      tunnel ? tunnel.tunnel_protocol : ''
    end

    def upgrade_head
      name = protocol
      return ''.b if name.empty?

      out = UPGRADE_LINE.dup
      out << UPGRADE_PREFIX << name << CRLF << CONNECTION_UPGRADE
      @headers.append_to(out)
      out << CRLF
    end

    def note_representation(size, type)
      @noted_length = size
      @noted_type = type
    end

    def unstream
      @stream_body = nil
      @stream_length = nil
      @tunnel = nil
    end

    def stream(status: 200, type: nil, length: nil, &body)
      raise ArgumentError, 'stream needs a block' unless body
      unless length.nil? || (length.is_a?(Integer) && length >= 0)
        raise ArgumentError, 'length must be a non-negative Integer'
      end

      @status = status
      @headers['Content-Type'] = type if type
      @body = ''
      @stream_length = length
      @stream_body = body
      @tunnel = nil
    end

    def sse(status: 200, &body)
      raise ArgumentError, 'sse needs a block' unless body

      @headers['Cache-Control'] = 'no-cache'
      @headers['X-Accel-Buffering'] = 'no'
      stream(status:, type: EVENT_STREAM, &body)
    end

    def streaming? = !@stream_body.nil?

    def text(body, status: 200)
      @status = status
      @headers.plain
      @body = body
      @stream_body = nil
      @tunnel = nil
    end

    def json(body, status: 200)
      @status = status
      @headers.json_type
      @body = body
      @stream_body = nil
      @tunnel = nil
    end

    def json_value(value, status: 200) = json(Json.generate(value), status: status)

    def set_cookie(name, value, path: '/', domain: nil, max_age: nil, secure: false, http_only: true,
                   same_site: 'Lax')
      @headers.add('Set-Cookie',
                   Cookies.serialize(name, value, path, domain, max_age, secure, http_only, same_site))
    end

    def delete_cookie(name, path: '/', domain: nil)
      @headers.add('Set-Cookie', Cookies.serialize(name, '', path, domain, 0, false, false, nil))
    end

    def to_wire(keep_alive, version: '1.1', head: false)
      Response.build_wire(@status, @headers, @body, keep_alive, version: version, head: head)
    end

    class << self
      def build_wire(status_value, headers, body_value, keep_alive, version: '1.1', head: false)
        status = valid_status?(status_value) ? status_value : 500
        body = payload(status_value, body_value)
        out = build_head(status_value, headers, body.bytesize, keep_alive, version: version)
        out << (body.ascii_only? ? body : body.b) unless head || no_body?(status)
        out
      end

      def build_head(status_value, headers, body_size, keep_alive, version: '1.1')
        old = version == HTTP_10
        valid = valid_status?(status_value)
        status = valid ? status_value : 500
        out = (+'').b
        line = (old ? STATUS_10 : STATUS_11)[status]
        if line
          out << line
        else
          out << (old ? PREFIX_10 : PREFIX_11) << status.to_s << UNKNOWN_REASON
        end
        if status == 205
          out << LENGTH_ZERO
        elsif body_size.negative?
          out << CHUNKED unless old
        elsif status != 204 && status != 304
          size = no_body?(status) ? 0 : body_size
          out << LENGTH_PREFIX << (size < LENGTHS.size ? LENGTHS[size] : size.to_s) << CRLF
        end
        unless valid && headers.date?
          out << DATE_PREFIX
          HttpDate.append(out)
          out << CRLF
        end
        if valid
          headers.append_to(out)
        end
        if keep_alive && old
          out << KEEP_ALIVE
        elsif !keep_alive
          out << CLOSE
        end
        out << CRLF
        out
      end

      def payload(status_value, body_value)
        return "internal error\n".b unless valid_status?(status_value)
        return ''.b if no_body?(status_value) || body_value.nil?

        body_value.is_a?(String) ? body_value : body_value.to_s
      end

      def stream_size(length) = length.nil? ? -1 : length

      def stream_framing(res, version, keep)
        length = res.stream_length
        chunked = length.nil? && version != HTTP_10
        [chunked, keep && (chunked || !length.nil?)]
      end

      def tunnels?(res) = res.status == SWITCHING && res.tunnel?

      def streams?(res)
        return false unless res.streaming?

        status = res.status
        valid_status?(status) && !no_body?(status)
      end

      def valid_status?(status_value) = status_value.is_a?(Integer) && status_value >= 200 && status_value <= 599
      def no_body?(status) = status == 204 || status == 205 || status == 304
    end
  end
end
