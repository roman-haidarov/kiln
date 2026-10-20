module Kiln
  module WsNative
    ffi_func :kiln_ws_accept, %i[str long], :binstr
    ffi_func :kiln_ws_mask, %i[str long long], :binstr
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

    attr_reader :protocol, :close_code, :close_reason

    def initialize(conn, protocol, max_message, ping_interval)
      @conn = conn
      @protocol = protocol
      @max_message = max_message
      @ping_interval = ping_interval
      @buffer = (+'').b
      @pos = 0
      @parts = (+'').b
      @kind = 0
      @write_lock = Mutex.new
      @sent_close = false
      @got_close = false
      @close_code = nil
      @close_reason = ''
      @ping_due = ping_interval ? Kiln.now + ping_interval : nil
      @pong_due = nil
      @expected_pong = nil
      @heartbeat_serial = 0
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
      raise ArgumentError, 'text message is not valid UTF-8' unless data.dup.force_encoding(Encoding::UTF_8).valid_encoding?

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

    class << self
      def accept(ctx, protocols, max_message, ping_interval, body)
        req = ctx.req
        res = ctx.res
        problem = handshake_problem(req)
        return refuse(res, problem) if problem

        chosen = choose(req.header('sec-websocket-protocol'), protocols)
        key = req.header('sec-websocket-key')
        res.headers['Sec-WebSocket-Accept'] = WsNative.kiln_ws_accept(key, key.bytesize)
        res.headers['Sec-WebSocket-Protocol'] = chosen unless chosen.empty?
        res.upgrade('websocket') do |conn|
          socket = WebSocket.new(conn, chosen, max_message, ping_interval)
          begin
            body.call(socket)
          ensure
            socket.finish
          end
        end
      end

      def handshake_problem(req)
        return 405 unless req.verb == 'GET'
        return 426 unless req.upgrade? && HttpSyntax.token_list?(req.header('upgrade'), 'websocket')
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

      def choose(offered, protocols)
        return '' if offered.nil? || protocols.empty?

        protocols.each { |name| return name if HttpSyntax.token_list?(offered, name) }
        ''
      end

      def header(opcode, size)
        out = (+'').b
        out << (0x80 | opcode)
        if size < 126
          out << size
        elsif size < 65_536
          out << 126 << (size >> 8) << (size & 0xFF)
        else
          out << 127
          7.downto(0) { |shift| out << ((size >> (shift * 8)) & 0xFF) }
        end
        out
      end
    end

    private

    def emit(opcode, data)
      @write_lock.synchronize do
        raise ClientGone, 'websocket is closed' if @sent_close && opcode != CLOSE

        @conn.write(WebSocket.header(opcode, data.bytesize) + data)
      end
      self
    end

    def send_close(code, reason)
      return if @sent_close

      payload = (+'').b
      if code != NO_STATUS && code != ABNORMAL
        payload << (code >> 8) << (code & 0xFF)
        payload << close_reason_bytes(reason)
      end
      begin
        emit(CLOSE, payload)
      rescue ClientGone, IOError, SystemCallError
        nil
      end
      @sent_close = true
      @close_code ||= code
    end

    def wait_close
      limit = Kiln.now + CLOSE_WAIT
      until @got_close
        left = limit - Kiln.now
        break if left <= 0

        frame = next_frame(left)
        break if frame.nil?

        handle(frame) if frame.opcode == CLOSE
      end
    rescue ClientGone, IOError, SystemCallError
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

    def available = @buffer.bytesize - @pos

    def fill(count, limit)
      while available < count
        wait = limit ? limit - Kiln.now : read_wait
        return false if limit && wait <= 0

        chunk = @conn.read(65_536, timeout: wait)
        if chunk.nil?
          @close_code ||= ABNORMAL
          @got_close = true
          return false
        end
        if chunk.empty?
          return false if limit || !tick
        else
          compact
          @buffer << chunk
        end
      end
      true
    rescue ClientGone
      @close_code ||= ABNORMAL
      @got_close = true
      false
    end

    def read_wait
      due = @pong_due || @ping_due
      return 1.0 if due.nil?

      left = due - Kiln.now
      left = 0.001 if left <= 0
      left > 1.0 ? 1.0 : left
    end

    def tick
      if @conn.closed?
        send_close(GOING_AWAY, 'server shutting down')
        return false
      end
      now = Kiln.now
      if @pong_due && now >= @pong_due
        reject(ABNORMAL)
        return false
      end
      if @ping_due && now >= @ping_due && @pong_due.nil?
        @heartbeat_serial += 1
        @expected_pong = [@heartbeat_serial].pack('Q>')
        ping(@expected_pong)
        @ping_due = now + @ping_interval
        @pong_due = now + @ping_interval
      end
      true
    end

    def compact
      return if @pos.zero?

      @buffer = @buffer.byteslice(@pos, @buffer.bytesize - @pos)
      @pos = 0
    end

    def byte(offset) = @buffer.getbyte(@pos + offset)

    def next_frame(limit = nil)
      deadline = limit ? Kiln.now + limit : nil
      return nil unless fill(2, deadline)

      first = byte(0)
      second = byte(1)
      return reject(PROTOCOL_ERROR) if first.anybits?(0x70) || !second.anybits?(0x80)

      size = second & 0x7F
      head = 2
      if size == 126
        return nil unless fill(4, deadline)

        size = (byte(2) << 8) | byte(3)
        head = 4
      elsif size == 127
        return nil unless fill(10, deadline)

        return reject(PROTOCOL_ERROR) if byte(2).anybits?(0x80)

        size = 0
        8.times { |index| size = (size << 8) | byte(2 + index) }
        head = 10
      end
      opcode = first & 0x0F
      return reject(TOO_BIG) if size > @max_message
      return nil unless fill(head + 4 + size, deadline)

      key = (byte(head) << 24) | (byte(head + 1) << 16) | (byte(head + 2) << 8) | byte(head + 3)
      raw = @buffer.byteslice(@pos + head + 4, size)
      @pos += head + 4 + size
      data = size.zero? ? EMPTY : WsNative.kiln_ws_mask(raw, size, key)
      Frame.new(opcode: opcode, fin: first.anybits?(0x80), data: data)
    end

    def handle(frame)
      opcode = frame.opcode
      fin = frame.fin
      data = frame.data
      return control(opcode, fin, data) if opcode >= CLOSE

      case opcode
      when TEXT, BINARY
        return reject(PROTOCOL_ERROR) unless @kind.zero?

        @kind = opcode
        @parts = (+'').b
      when CONTINUATION
        return reject(PROTOCOL_ERROR) if @kind.zero?
      else
        return reject(PROTOCOL_ERROR)
      end
      return reject(TOO_BIG) if @parts.bytesize + data.bytesize > @max_message

      @parts << data
      return nil unless fin

      complete
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
      when PONG
        if @expected_pong && data == @expected_pong
          @pong_due = nil
          @expected_pong = nil
        end
      else return reject(PROTOCOL_ERROR)
      end
      nil
    end

    def pong(data)
      emit(PONG, data)
    rescue ClientGone
      nil
    end

    def close_frame(data)
      @got_close = true
      if data.bytesize == 1
        @close_code = PROTOCOL_ERROR
      elsif data.bytesize >= 2
        code = (data.getbyte(0) << 8) | data.getbyte(1)
        reason = data.byteslice(2, data.bytesize - 2).force_encoding(Encoding::UTF_8)
        readable = reason.valid_encoding?
        @close_code = if !valid_code?(code) then PROTOCOL_ERROR
                      elsif readable then code
                      else INVALID_DATA
                      end
        @close_reason = readable ? reason : ''
      else
        @close_code = NO_STATUS
      end
      reply_code = @close_code == NO_STATUS || @close_code == 1010 ? NORMAL : @close_code
      send_close(reply_code, '')
    end

    def valid_code?(code)
      code.is_a?(Integer) && ((code >= 1000 && code <= 1003) || (code >= 1007 && code <= 1014) ||
        (code >= 3000 && code <= 4999))
    end

    def valid_reason?(reason)
      reason.to_s.b.dup.force_encoding(Encoding::UTF_8).valid_encoding?
    end

    def close_reason_bytes(reason)
      bytes = reason.to_s.b
      bytes = bytes.byteslice(0, MAX_CONTROL - 2) if bytes.bytesize > MAX_CONTROL - 2
      while !bytes.dup.force_encoding(Encoding::UTF_8).valid_encoding?
        bytes = bytes.byteslice(0, bytes.bytesize - 1)
      end
      bytes
    end
  end
end
