module Kiln
  class Server
    class Settings
      include Runtime::Check

      SHARED = {
        log: nil, host: '0.0.0.0', port: 0, listen: nil, tls: nil, max_conns: 10_000, max_body: 1 << 20,
        buffer_body: nil, backlog: 1024, tcp_nodelay: true, reuse_port: false, max_connection_rate: 256,
        read_timeout: 5.0, request_timeout: 2.0, write_timeout: 10.0, header_timeout: nil, keep_alive_timeout: nil
      }.freeze
      EVENT = SHARED.merge(host: '127.0.0.1', handlers: 0, max_streams: 1024, client_disconnect_timeout: 1.0).freeze
      BASE = SHARED.merge(host: '127.0.0.1', kill_grace: 1.0, coop_budget: 4, shards: 1,
                          client_disconnect_timeout: 0.5).freeze
      RULES = [
        [:max_conns, 'max_conns', :int_at_least_one], [:max_body, 'max_body', :int_at_least_zero],
        [:read_timeout, 'read_timeout', :seconds_above], [:request_timeout, 'request_timeout', :seconds_above],
        [:write_timeout, 'write_timeout', :seconds_above], [:handlers, 'handlers', :int_at_least_zero],
        [:max_streams, 'max_streams', :int_at_least_one], [:kill_grace, 'kill_grace', :seconds_at_least],
        [:coop_budget, 'cooperative budget', :int_at_least_zero], [:shards, 'shards', :int_at_least_one],
        [:backlog, 'backlog', :int_at_least_one], [:max_connection_rate, 'max_connection_rate', :int_at_least_zero],
        [:client_disconnect_timeout, 'client_disconnect_timeout', :seconds_at_least],
        [:header_timeout, 'header_timeout', :seconds_above],
        [:keep_alive_timeout, 'keep_alive_timeout', :seconds_at_least],
        [:buffer_body, 'buffer_body', :int_at_least_zero]
      ].freeze

      class << self
        def event(options) = new(options, EVENT)

        def base(options)
          settings = new(options, BASE)
          raise ArgumentError, 'tls needs the event backend' unless settings.tls.nil? && settings.listen.none?(&:tls?)

          settings
        end

        def log(value)
          return value if value.nil? || value.is_a?(Observability::Log)

          raise ArgumentError, 'log must be a Kiln::Observability::Log'
        end
      end

      def initialize(options, defaults)
        unknown = options.keys - defaults.keys
        raise ArgumentError, "unknown keyword: :#{unknown.first}" unless unknown.empty?

        @raw = defaults.merge(options)
        validate(defaults)
      end

      def log = Settings.log(@raw[:log])
      def host = @raw[:host].to_s
      def port = @raw[:port].to_i
      def tls = @raw[:tls].is_a?(Transport::Tls) ? @raw[:tls] : nil
      def listen = Transport::Listen.resolve(@raw[:listen], host, port, tls)
      def max_conns = @raw[:max_conns].to_i
      def max_body = @raw[:max_body].to_i
      def buffer_body = (@raw[:buffer_body] || @raw[:max_body]).to_i
      def backlog = @raw[:backlog].to_i
      def tcp_nodelay? = @raw[:tcp_nodelay] ? true : false
      def reuse_port? = @raw[:reuse_port] ? true : false
      def max_connection_rate = @raw[:max_connection_rate].to_i
      def read_timeout = @raw[:read_timeout].to_f
      def request_timeout = @raw[:request_timeout].to_f
      def write_timeout = @raw[:write_timeout].to_f
      def header_timeout = (@raw[:header_timeout] || @raw[:read_timeout]).to_f
      def keep_alive_timeout = (@raw[:keep_alive_timeout] || @raw[:read_timeout]).to_f
      def client_disconnect_timeout = @raw[:client_disconnect_timeout].to_f
      def handlers = @raw[:handlers].to_i
      def max_streams = @raw[:max_streams].to_i
      def kill_grace = @raw[:kill_grace].to_f
      def coop_budget = @raw[:coop_budget].to_i
      def shards = @raw[:shards].to_i

      private

      def validate(defaults)
        check_rules(rule_rows(defaults))
        raise ArgumentError, 'port' unless valid_port?
        raise ArgumentError, 'tls must be a Transport::Tls' unless @raw[:tls].nil? || tls
        raise ArgumentError, 'reuse_port needs a fixed TCP port (port: 0 cannot share one port)' if shared_port_zero?
        return unless buffer_body > max_body

        raise ArgumentError, 'buffer_body must not exceed max_body (route limits can be larger)'
      end

      def rule_rows(defaults)
        rows = []
        RULES.each do |key, name, kind|
          value = @raw[key]
          rows << [name, value, kind] if defaults.key?(key) && !(value.nil? && defaults[key].nil?)
        end
        rows
      end

      def valid_port? = @raw[:port].is_a?(Integer) && @raw[:port] >= 0 && @raw[:port] <= 65_535

      def shared_port_zero?
        reuse_port? && listen.any? { |spec| spec.kind == :tcp && spec.port.zero? }
      end
    end

  end
end
