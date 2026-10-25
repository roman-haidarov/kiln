module Kiln
  class Server
    class Event
      include Runtime::Check

      EMPTY_BODY = ''.b.freeze
      LIVENESS_EVERY = 1.0
      HANDLER_WAIT = 0.25
      OUT_HIGH = 256 * 1024
      OUT_LOW = 64 * 1024
      HEAD = 'HEAD'.freeze
      META = 8
      STREAMED = 1
      TLS_FLAG = 8
      TAKE_DATA = 1
      TAKE_EOF = 2
      TAKE_WAIT = 0
      BAD_REQUEST = "HTTP/1.1 400 Bad Request\r\nContent-Length: 12\r\nConnection: close\r\n\r\nbad request\n".b.freeze
      DEADLINE_BODY = "deadline exceeded\n".freeze

      Dispatch = Struct.new(:ctx, :slot, :gen)

      Job = Struct.new(:ctx, :slot, :gen, :thread, :claimed, :claim_lock) do
        def claim!
          claim_lock.synchronize do
            return false if claimed

            self.claimed = true
          end
        end
      end

    end
  end
end
