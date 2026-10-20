module Kiln
  class Server
    class Base
      class BodySource
        attr_reader :sock, :buf, :length, :chunk_state
        attr_accessor :state, :remaining, :expect

        def initialize(server, sock, buf, length, expect)
          @server = server
          @sock = sock
          @buf = buf
          @length = length
          @remaining = length || 0
          @chunk_state = [0, 0, 0, 0, 0, 0]
          @expect = expect
          @state = length.nil? ? :chunked : :data
        end

        def pull(max) = @server.body_pull(self, max)
        def done? = @state == :done
      end
    end
  end
end
