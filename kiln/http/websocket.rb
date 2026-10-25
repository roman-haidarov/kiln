module Kiln
  module HTTP
    module WsNative
      ffi_func :kiln_ws_accept, %i[str long], :binstr
      ffi_func :kiln_ws_mask, %i[str long long], :binstr
    end

    module WsOrigins
      ANY = '*'.freeze
      SAME_HOST = [ANY].drop(1).freeze
      DEFAULT_PORTS = { 'http' => ':80', 'https' => ':443' }.freeze

      class << self
        def policy(origins)
          return SAME_HOST if origins.nil?
          raise ArgumentError, 'origins must be nil or a non-empty list of strings' unless list?(origins)

          origins.map { |item| item.downcase.freeze }.freeze
        end

        def allowed?(origin, host, policy, scheme = 'http')
          return true if origin.nil?
          return same_host?(origin.downcase, host, scheme) if policy.empty?

          policy.include?(ANY) || policy.include?(origin.downcase)
        end

        private

        def list?(origins)
          origins.is_a?(Array) && !origins.empty? && origins.all? { |item| item.is_a?(String) }
        end

        def same_host?(origin, host, request_scheme)
          return false if host.nil? || host.empty?

          scheme, authority = origin.split('://', 2)
          port = DEFAULT_PORTS[scheme]
          return false if port.nil? || authority.nil? || authority.empty? || authority.include?('/')
          return false if request_scheme == 'https' && scheme != 'https'

          bare(authority, port) == bare(host.downcase, port)
        end

        def bare(authority, port) = authority.end_with?(port) ? authority.delete_suffix(port) : authority
      end
    end

    class WebSocket
      MAX_MESSAGE = 1 << 20
      MAX_CONTROL = 125
      CLOSE_WAIT = 1.0
      VERSION = '13'.freeze
      KEY = %r{\A[A-Za-z0-9+/]{22}==\z}
      CONTINUATION = 0
      TEXT = 1
      BINARY = 2
      CLOSE = 8
      PING = 9
      PONG = 10
      NORMAL = 1000
      GOING_AWAY = 1001
      PROTOCOL_ERROR = 1002
      NO_STATUS = 1005
      ABNORMAL = 1006
      INVALID_DATA = 1007
      TOO_BIG = 1009
      EMPTY = ''.b.freeze

      Frame = Data.define(:opcode, :fin, :data)
      Message = Data.define(:type, :data) do
        def text? = type == :text
        def binary? = type == :binary
      end

      module Handshake
        def accept(ctx, protocols, max_message, ping_interval, origins, body)
          req = ctx.req
          res = ctx.res
          problem = handshake_problem(req)
          return refuse(res, problem) if problem
          return forbid(res) unless WsOrigins.allowed?(req.header('origin'), req.header('host'), origins, req.scheme)

          chosen = choose(req.header('sec-websocket-protocol'), protocols)
          accept_headers(res, req.header('sec-websocket-key'), chosen)
          res.upgrade('websocket', idle_timeout: nil) do |conn|
            serve(WebSocket.new(conn, chosen, max_message, ping_interval), body)
          end
        end

        def handshake_problem(req)
          return 405 unless req.verb == 'GET'
          return 426 unless req.upgrade? && Syntax.token_list?(req.header('upgrade'), 'websocket')
          return 426 unless req.header('sec-websocket-version') == VERSION
          return 400 unless KEY.match?(req.header('sec-websocket-key').to_s)

          nil
        end

        def refuse(res, status)
          res.headers['Sec-WebSocket-Version'] = VERSION
          res.headers['Upgrade'] = 'websocket' if status == 426
          res.headers['Allow'] = 'GET' if status == 405
          res.text("websocket handshake required\n", status: status)
        end

        def forbid(res) = res.text("websocket origin not allowed\n", status: 403)

        def choose(offered, protocols)
          return '' if offered.nil? || protocols.empty?

          protocols.each { |name| return name if Syntax.token_list?(offered, name) }
          ''
        end

        def header(opcode, size)
          out = (+'').b
          out << (0x80 | opcode)
          if size < 126
            out << size
            return out
          end
          if size < 65_536
            out << 126 << (size >> 8) << (size & 0xFF)
            return out
          end

          out << 127
          7.downto(0) { |shift| out << ((size >> (shift * 8)) & 0xFF) }
          out
        end

        private

        def accept_headers(res, key, chosen)
          res.headers['Sec-WebSocket-Accept'] = WsNative.kiln_ws_accept(key, key.bytesize)
          res.headers['Sec-WebSocket-Protocol'] = chosen unless chosen.empty?
        end

        def serve(socket, body)
          body.call(socket)
        ensure
          socket.finish
        end
      end

      module Heartbeat
        private

        def init_heartbeat(ping_interval)
          @ping_interval = ping_interval
          @ping_due = ping_interval ? Kiln::Runtime.now + ping_interval : nil
          @pong_due = nil
          @expected_pong = nil
          @heartbeat_serial = 0
        end

        def read_wait
          due = @pong_due || @ping_due
          return 1.0 if due.nil?

          left = due - Kiln::Runtime.now
          left = 0.001 if left <= 0
          [left, 1.0].min
        end

        def tick?
          now = Kiln::Runtime.now
          return false unless heartbeat_ok?(now)

          heartbeat(now) if @ping_due && now >= @ping_due && @pong_due.nil?
          true
        end

        def heartbeat_ok?(now)
          if @conn.closed?
            send_close(GOING_AWAY, 'server shutting down')
          elsif @pong_due && now >= @pong_due
            reject(ABNORMAL)
          else
            return true
          end
          false
        end

        def heartbeat(now)
          @heartbeat_serial += 1
          @expected_pong = [@heartbeat_serial].pack('Q>')
          ping(@expected_pong)
          @ping_due = now + @ping_interval
          @pong_due = now + @ping_interval
        end
      end

      module Reader
        private

        def init_buffers
          @buffer = (+'').b
          @pos = 0
          @parts = (+'').b
          @kind = 0
        end

        def available = @buffer.bytesize - @pos

        def fill(count, limit)
          while available < count
            return false unless read_more?(limit)
          end
          true
        rescue Runtime::ClientGone
          mark_lost
          false
        end

        def read_more?(limit)
          wait = limit ? limit - Kiln::Runtime.now : read_wait
          return false if limit && wait <= 0

          absorb?(@conn.read(65_536, timeout: wait), limit)
        end

        def absorb?(chunk, limit)
          if chunk.nil?
            mark_lost
            return false
          end
          return !limit && tick? if chunk.empty?

          compact
          @buffer << chunk
          true
        end

        def mark_lost
          @close_code ||= ABNORMAL
          @got_close = true
        end

        def compact
          return if @pos.zero?

          @buffer = @buffer.byteslice(@pos, @buffer.bytesize - @pos)
          @pos = 0
        end

        def byte(offset) = @buffer.getbyte(@pos + offset)

        def next_frame(limit = nil)
          deadline = deadline_after(limit)
          return nil unless fill(2, deadline)

          first = byte(0)
          return reject(PROTOCOL_ERROR) if bad_head?(first, byte(1))

          head, size = frame_size(byte(1) & 0x7F, deadline)
          return nil if head.zero?
          return reject(TOO_BIG) if size > @max_message
          return nil unless fill(head + 4 + size, deadline)

          build_frame(first, head, size)
        end

        def build_frame(first, head, size)
          Frame.new(opcode: first & 0x0F, fin: first.anybits?(0x80), data: unmask(head, size))
        end

        def deadline_after(limit) = limit ? Kiln::Runtime.now + limit : nil

        def bad_head?(first, second) = first.anybits?(0x70) || !second.anybits?(0x80)

        def frame_size(size, deadline)
          return [2, size] if size < 126
          return extended_size(deadline) if size == 127
          return [0, 0] unless fill(4, deadline)

          length = (byte(2) << 8) | byte(3)
          if length < 126
            reject(PROTOCOL_ERROR)
            return [0, 0]
          end
          [4, length]
        end

        def extended_size(deadline)
          return [0, 0] unless fill(10, deadline)

          if byte(2).anybits?(0x80)
            reject(PROTOCOL_ERROR)
            return [0, 0]
          end
          size = 0
          8.times { |index| size = (size << 8) | byte(2 + index) }
          if size < 65_536
            reject(PROTOCOL_ERROR)
            return [0, 0]
          end
          [10, size]
        end

        def unmask(head, size)
          key = mask_key(head)
          raw = @buffer.byteslice(@pos + head + 4, size)
          @pos += head + 4 + size
          size.zero? ? EMPTY : WsNative.kiln_ws_mask(raw, size, key)
        end

        def mask_key(head)
          (byte(head) << 24) | (byte(head + 1) << 16) | (byte(head + 2) << 8) | byte(head + 3)
        end
      end

      module Frames
        private

        def handle(frame)
          opcode = frame.opcode
          data = frame.data
          return control(opcode, frame.fin, data) if opcode >= CLOSE
          return reject(PROTOCOL_ERROR) unless accept_part?(opcode)
          return reject(TOO_BIG) if @parts.bytesize + data.bytesize > @max_message

          @parts << data
          frame.fin ? complete : nil
        end

        def accept_part?(opcode)
          case opcode
          when TEXT, BINARY
            return false unless @kind.zero?

            @kind = opcode
            @parts = (+'').b
            true
          when CONTINUATION then !@kind.zero?
          else false
          end
        end

        def complete
          kind = @kind
          data = @parts
          @kind = 0
          @parts = (+'').b
          return Message.new(type: :binary, data: data) if kind == BINARY

          text = data.force_encoding(Encoding::UTF_8)
          return reject(INVALID_DATA) unless text.valid_encoding?

          Message.new(type: :text, data: text)
        end

        def control(opcode, fin, data)
          return reject(PROTOCOL_ERROR) if !fin || data.bytesize > MAX_CONTROL

          case opcode
          when CLOSE then close_frame(data)
          when PING then pong(data)
          when PONG then pong_received(data)
          else return reject(PROTOCOL_ERROR)
          end
          nil
        end

        def pong(data)
          emit(PONG, data)
        rescue Runtime::ClientGone
          nil
        end

        def pong_received(data)
          return unless @expected_pong && data == @expected_pong

          @pong_due = nil
          @expected_pong = nil
        end

        def close_frame(data)
          @got_close = true
          @close_code = received_code(data)
          reply_code = @close_code == NO_STATUS || @close_code == 1010 ? NORMAL : @close_code
          send_close(reply_code, '')
        end

        def received_code(data)
          size = data.bytesize
          return NO_STATUS if size.zero?
          return PROTOCOL_ERROR if size == 1

          reason = data.byteslice(2, size - 2).force_encoding(Encoding::UTF_8)
          readable = reason.valid_encoding?
          @close_reason = readable ? reason : ''
          code = (data.getbyte(0) << 8) | data.getbyte(1)
          return PROTOCOL_ERROR unless valid_code?(code)

          readable ? code : INVALID_DATA
        end
      end

      module Closing
        private

        def init_close
          @sent_close = false
          @got_close = false
          @close_code = nil
          @close_reason = ''
        end

        def emit(opcode, data)
          @write_lock.synchronize do
            raise Runtime::ClientGone, 'websocket is closed' if @sent_close && opcode != CLOSE

            @conn.write(WebSocket.header(opcode, data.bytesize) + data)
          end
          self
        end

        def send_close(code, reason)
          return if @sent_close

          begin
            emit(CLOSE, close_payload(code, reason))
          rescue Runtime::ClientGone, IOError, SystemCallError
            nil
          end
          @sent_close = true
          @send_close ||= code
        end

        def close_payload(code, reason)
          payload = (+'').b
          return payload if [NO_STATUS, ABNORMAL].include?(code)

          payload << (code >> 8) << (code & 0xFF)
          payload << close_reason_bytes(reason)
        end

        def wait_close
          limit = Kiln::Runtime.now + CLOSE_WAIT
          until @got_close
            left = limit - Kiln::Runtime.now
            break if left <= 0

            frame = next_frame(left)
            break if frame.nil?

            handle(frame) if frame.opcode == CLOSE
          end
        rescue Runtime::ClientGone, IOError, SystemCallError
          nil
        end

        def finish_conn
          @conn.close
        end

        def reject(code)
          @close_code = code
          send_close(code, '')
          finish_conn
          nil
        end

        def valid_code?(code)
          code.is_a?(Integer) && (code.between?(1000, 1003) || code.between?(1007, 1014) ||
            code.between?(3000, 4999))
        end

        def valid_reason?(reason)
          reason.to_s.b.dup.force_encoding(Encoding::UTF_8).valid_encoding?
        end

        def close_reason_bytes(reason)
          bytes = reason.to_s.b
          bytes = bytes.byteslice(0, MAX_CONTROL - 2) if bytes.bytesize > MAX_CONTROL - 2
          bytes = bytes.byteslice(0, bytes.bytesize - 1) until bytes.dup.force_encoding(Encoding::UTF_8).valid_encoding?
          bytes
        end
      end

      extend Handshake
      include Reader
      include Heartbeat
      include Frames
      include Closing

      attr_reader :protocol, :close_code, :close_reason

      def initialize(conn, protocol, max_message, ping_interval)
        @conn = conn
        @protocol = protocol
        @max_message = max_message
        @write_lock = Mutex.new
        init_buffers
        init_close
        init_heartbeat(ping_interval)
      end

      def receive
        loop do
          return nil if closed?

          frame = next_frame
          return nil if frame.nil?

          message = handle(frame)
          return message if message
        end
      end

      def each
        while (message = receive)
          yield message
        end
        self
      end

      def send_text(text)
        data = text.to_s
        valid = data.dup.force_encoding(Encoding::UTF_8).valid_encoding?
        raise ArgumentError, 'text message is not valid UTF-8' unless valid

        emit(TEXT, data.b)
      end

      def send_binary(data) = emit(BINARY, data.to_s.b)

      def ping(data = EMPTY)
        raise ArgumentError, 'ping payload exceeds 125 bytes' if data.bytesize > MAX_CONTROL

        emit(PING, data.b)
      end

      def close(code = NORMAL, reason = '')
        raise ArgumentError, 'invalid websocket close code' unless valid_code?(code) && code != 1010
        raise ArgumentError, 'websocket close reason is not valid UTF-8' unless valid_reason?(reason)

        send_close(code, reason)
        wait_close
        finish_conn
        self
      end

      def closed? = @got_close || @sent_close || @conn.closed?

      def finish
        send_close(@conn.closed? ? GOING_AWAY : NORMAL, '') unless @sent_close
        wait_close
        finish_conn
      end
    end
  end
end
