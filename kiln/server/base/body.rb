module Kiln
  class Server
    class Base
      class BodySource
        attr_reader :sock, :buf, :length
        attr_accessor :state, :remaining, :chunk_left, :excess, :expect

        def initialize(server, sock, buf, length, expect)
          @server = server
          @sock = sock
          @buf = buf
          @length = length
          @remaining = length || 0
          @chunk_left = 0
          @excess = 0
          @expect = expect
          @state = length.nil? ? :size : :data
        end

        def pull(max) = @server.body_pull(self, max)
        def done? = @state == :done
      end
    end
  end
end
