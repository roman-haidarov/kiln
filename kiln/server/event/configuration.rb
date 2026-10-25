module Kiln
  class Server
    module EventConfiguration
      class << self
        def pack(config)
          [config.max_conns, config.buffer_body,
           millis(config.header_timeout), millis(config.keep_alive_timeout), millis(config.read_timeout),
           millis(config.write_timeout), millis(config.client_disconnect_timeout),
           config.tcp_nodelay? ? 1 : 0, config.max_connection_rate, config.backlog]
        end

        private

        def millis(seconds)
          (seconds * 1000).to_i
        end
      end
    end
  end
end
