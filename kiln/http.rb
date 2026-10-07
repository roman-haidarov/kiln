module Kiln
  class Request
    attr_reader :verb, :path, :query, :headers, :body
    attr_accessor :params

    def initialize(verb, target, headers, body)
      @verb = verb
      p, q = target.split("?", 2)
      @path = p.to_s
      @query = q || ""
      @headers = headers
      @body = body
      @params = {}
    end

    def header(name) = @headers[name.downcase]
  end

  class Response
    REASONS = { 200 => "OK", 201 => "Created", 400 => "Bad Request", 404 => "Not Found",
                500 => "Internal Server Error", 503 => "Service Unavailable", 504 => "Gateway Timeout" }
    attr_accessor :status, :body
    attr_reader :headers

    def initialize
      @status = 200
      @headers = {}
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

    def to_wire(keep_alive)
      out = +"HTTP/1.1 #{@status} #{REASONS[@status] || "Unknown"}\r\nContent-Length: #{@body.bytesize}\r\n"
      @headers.each { |k, v| out << k << ": " << v << "\r\n" }
      out << "Connection: close\r\n" unless keep_alive
      out << "\r\n" << @body
    end
  end
end
