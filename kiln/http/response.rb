module Kiln
  module HTTP
    module ResponseWire
      def fixed_parts(req, res, keep)
        status = res.status
        body = payload(status, res.body)
        head = build_head(status, res.headers, body.bytesize, keep, version: req.http_version)
        [head, body_for(req.verb, status, body)]
      end

      def body_for(verb, status, body)
        verb == 'HEAD' || no_body?(status) ? Response::EMPTY_BODY : body
      end

      def build_wire(status_value, headers, body_value, keep_alive, version: '1.1')
        status = valid_status?(status_value) ? status_value : 500
        body = payload(status_value, body_value)
        out = build_head(status_value, headers, body.bytesize, keep_alive, version: version)
        out << (body.ascii_only? ? body : body.b) unless no_body?(status)
        out
      end

      def build_head(status_value, headers, body_size, keep_alive, version: '1.1')
        old = version == Response::HTTP_10
        valid = valid_status?(status_value)
        status = valid ? status_value : 500
        out = status_line(status, old)
        append_framing(out, status, body_size, old)
        append_date(out) unless valid && headers.date?
        headers.append_to(out) if valid
        append_connection(out, keep_alive, old)
        out << Response::CRLF
      end

      def payload(status_value, body_value)
        return "internal error\n".b unless valid_status?(status_value)
        return ''.b if no_body?(status_value) || body_value.nil?

        body_value.is_a?(String) ? body_value : body_value.to_s
      end

      def stream_size(length) = length.nil? ? -1 : length

      def stream_framing(res, version, keep)
        length = res.stream_length
        chunked = length.nil? && version != Response::HTTP_10
        [chunked, keep && (chunked || !length.nil?)]
      end

      def tunnels?(res) = res.status == Response::SWITCHING && res.tunnel?

      def streams?(res)
        return false unless res.streaming?

        status = res.status
        valid_status?(status) && !no_body?(status)
      end

      def valid_status?(status_value) = status_value.is_a?(Integer) && status_value >= 200 && status_value <= 599
      def no_body?(status) = [204, 205, 304].include?(status)

      private

      def status_line(status, old)
        out = (+'').b
        line = (old ? Response::STATUS_10 : Response::STATUS_11)[status]
        return out << line if line

        out << (old ? Response::PREFIX_10 : Response::PREFIX_11) << status.to_s << Response::UNKNOWN_REASON
      end

      def append_framing(out, status, body_size, old)
        if status == 205
          out << Response::LENGTH_ZERO
        elsif body_size.negative?
          out << Response::CHUNKED unless old
        elsif status != 204 && status != 304
          out << Response::LENGTH_PREFIX << length_text(body_size) << Response::CRLF
        end
        out
      end

      def length_text(size)
        lengths = Response::LENGTHS
        size < lengths.size ? lengths[size] : size.to_s
      end

      def append_date(out)
        out << Response::DATE_PREFIX
        Date.append(out)
        out << Response::CRLF
      end

      def append_connection(out, keep_alive, old)
        if keep_alive && old
          out << Response::KEEP_ALIVE
        elsif !keep_alive
          out << Response::CLOSE
        end
        out
      end
    end

    module ResponseTunnel
      def upgrade(protocol, &body)
        raise ArgumentError, 'upgrade needs a block' unless body
        raise ArgumentError, 'upgrade protocol must be a token' unless Native.token?(protocol.to_s)

        open_tunnel(protocol.to_s, body)
      end

      def hijack(&body)
        raise ArgumentError, 'hijack needs a block' unless body

        open_tunnel('', body)
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

        out = Response::UPGRADE_LINE.dup
        out << Response::UPGRADE_PREFIX << name << Response::CRLF << Response::CONNECTION_UPGRADE
        @headers.append_to(out)
        out << Response::CRLF
      end

      private

      def open_tunnel(protocol, body)
        @status = Response::SWITCHING
        @body = ''
        @stream_body = nil
        @tunnel = Response::Upgrade.new(protocol, body)
      end
    end

    module ResponseCookies
      def set_cookie(name, value, **attributes)
        @headers.add('Set-Cookie', Cookies.serialize(Cookies.build(name, value, attributes)))
      end

      def delete_cookie(name, path: '/', domain: nil)
        attributes = { path: path, domain: domain, max_age: 0, secure: false, http_only: false, same_site: nil }
        cookie = Cookies::Cookie.new(name, '', attributes)
        @headers.add('Set-Cookie', Cookies.serialize(cookie))
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
      EMPTY_BODY = ''.b.freeze
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
      STATUS_11 = REASONS.to_h { |code, reason| [code, "HTTP/1.1 #{code} #{reason}\r\n".b.freeze] }.freeze
      STATUS_10 = REASONS.to_h { |code, reason| [code, "HTTP/1.0 #{code} #{reason}\r\n".b.freeze] }.freeze
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

      extend ResponseWire
      include ResponseTunnel
      include ResponseCookies

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
        raise ArgumentError, 'length must be a non-negative Integer' unless stream_length?(length)

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
        @headers.plain
        fixed(body, status)
      end

      def json(body, status: 200)
        @headers.json_type
        fixed(body, status)
      end

      def json_value(value, status: 200) = json(Json.generate(value), status: status)

      def to_wire(keep_alive, version: '1.1', head: false)
        return Response.build_wire(@status, @headers, @body, keep_alive, version: version) unless head

        size = Response.payload(@status, @body).bytesize
        Response.build_head(@status, @headers, size, keep_alive, version: version)
      end

      private

      def stream_length?(length) = length.nil? || (length.is_a?(Integer) && length >= 0)

      def fixed(body, status)
        @status = status
        @body = body
        @stream_body = nil
        @tunnel = nil
      end
    end
  end
end
