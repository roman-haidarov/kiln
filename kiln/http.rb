module Kiln
  module HttpDate
    FORMAT = "%a, %d %b %Y %H:%M:%S GMT"

    class << self
      def value
        sec = Process.clock_gettime(Process::CLOCK_REALTIME, :second)
        cached = @cached
        return cached[1] if cached && cached[0] == sec
        text = Time.now.utc.strftime(FORMAT).b.freeze
        @cached = [sec, text].freeze
        text
      end
    end
  end

  class Request
    EMPTY_PARAMS = {}.freeze

    attr_reader :verb, :path, :query, :headers, :body, :http_version
    attr_accessor :params

    def initialize(verb, target, headers, body, http_version: "1.1")
      @verb = verb
      text = target.to_s
      cut = text.byteindex("?")
      @path = cut ? text.byteslice(0, cut) : text
      @query = cut ? text.byteslice(cut + 1, text.bytesize - cut - 1) : ""
      @headers = headers
      @body = body
      @http_version = http_version == "1.0" ? "1.0" : "1.1"
      @params = EMPTY_PARAMS
    end

    def header(name) = @headers[name] || @headers[name.downcase]
  end

  class Headers
    HOP = %w[content-length transfer-encoding connection].freeze

    def initialize
      @items = []
      @date = false
    end

    def []=(name, value)
      key = name.to_s.downcase
      delete(key)
      store(name.to_s, key, value.to_s)
    end

    def add(name, value)
      store(name.to_s, name.to_s.downcase, value.to_s)
    end

    def [](name)
      key = name.to_s.downcase
      i = 1
      while i < @items.size
        return @items[i + 1] if @items[i] == key
        i += 3
      end
      nil
    end

    def key?(name) = !self[name].nil?

    def delete(name)
      key = name.to_s.downcase
      i = @items.size - 2
      while i >= 1
        @items.slice!(i - 1, 3) if @items[i] == key
        i -= 3
      end
      @date = false if key == "date"
    end

    def each
      i = 0
      while i < @items.size
        yield @items[i], @items[i + 2]
        i += 3
      end
    end

    def size = @items.size / 3
    def date? = @date

    private

    def store(name, key, value)
      return false unless HttpNative.token?(name)
      return false if HOP.include?(key)
      return false if HttpNative.ctl?(value)
      @items.push(name)
      @items.push(key)
      @items.push(value)
      @date = true if key == "date"
      true
    end
  end

  class Response
    REASONS = {
      200 => "OK", 201 => "Created", 204 => "No Content",
      301 => "Moved Permanently", 302 => "Found", 304 => "Not Modified",
      400 => "Bad Request", 401 => "Unauthorized", 403 => "Forbidden",
      404 => "Not Found", 405 => "Method Not Allowed", 408 => "Request Timeout", 417 => "Expectation Failed",
      413 => "Payload Too Large", 431 => "Request Header Fields Too Large",
      500 => "Internal Server Error", 501 => "Not Implemented", 503 => "Service Unavailable",
      504 => "Gateway Timeout"
    }.freeze
    HTTP_10 = "1.0".freeze
    CRLF = "\r\n".b.freeze
    FIELD_SEP = ": ".b.freeze
    PREFIX_11 = "HTTP/1.1 ".b.freeze
    PREFIX_10 = "HTTP/1.0 ".b.freeze
    UNKNOWN_REASON = " Status\r\n".b.freeze
    LENGTH_PREFIX = "Content-Length: ".b.freeze
    LENGTH_ZERO = "Content-Length: 0\r\n".b.freeze
    DATE_PREFIX = "Date: ".b.freeze
    KEEP_ALIVE = "Connection: keep-alive\r\n".b.freeze
    CLOSE = "Connection: close\r\n".b.freeze
    LENGTHS = Array.new(4097) { |n| n.to_s.b.freeze }.freeze
    STATUS_11 = {}
    STATUS_10 = {}
    REASONS.each do |code, reason|
      STATUS_11[code] = "HTTP/1.1 #{code} #{reason}\r\n".b.freeze
      STATUS_10[code] = "HTTP/1.0 #{code} #{reason}\r\n".b.freeze
    end
    STATUS_11.freeze
    STATUS_10.freeze
    attr_accessor :status, :body
    attr_reader :headers

    def initialize
      @status = 200
      @headers = Headers.new
      @body = ""
    end

    def text(s, status: 200)
      @status = status
      @headers["Content-Type"] = "text/plain"
      @body = s
    end

    def json(s, status: 200)
      @status = status
      @headers["Content-Type"] = "application/json"
      @body = s
    end

    def to_wire(keep_alive, version: "1.1", head: false)
      Response.build_wire(@status, @headers, @body, keep_alive, version: version, head: head)
    end

    class << self
      def build_wire(status_value, headers, body_value, keep_alive, version: "1.1", head: false)
        status = valid_status?(status_value) ? status_value : 500
        body = payload(status_value, body_value)
        out = build_head(status_value, headers, body.bytesize, keep_alive, version: version)
        out << (body.ascii_only? ? body : body.b) unless head || no_body?(status)
        out
      end

      def build_head(status_value, headers, body_size, keep_alive, version: "1.1")
        old = version == HTTP_10
        valid = valid_status?(status_value)
        status = valid ? status_value : 500
        out = (+"").b
        line = (old ? STATUS_10 : STATUS_11)[status]
        if line
          out << line
        else
          out << (old ? PREFIX_10 : PREFIX_11) << status.to_s << UNKNOWN_REASON
        end
        if status == 205
          out << LENGTH_ZERO
        elsif status != 204 && status != 304
          size = no_body?(status) ? 0 : body_size
          out << LENGTH_PREFIX << (size < LENGTHS.size ? LENGTHS[size] : size.to_s) << CRLF
        end
        out << DATE_PREFIX << HttpDate.value << CRLF unless valid && headers.date?
        if valid
          headers.each { |name, value| out << name << FIELD_SEP << (value.ascii_only? ? value : value.b) << CRLF }
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
        return "".b if no_body?(status_value)
        return "".b if body_value.nil?
        body_value.is_a?(String) ? body_value : body_value.to_s
      end

      def valid_status?(status_value) = status_value.is_a?(Integer) && status_value >= 200 && status_value <= 599
      def no_body?(status) = status == 204 || status == 205 || status == 304
    end
  end
end
