module Kiln
  class Server
    module Rules
      include Runtime::Check

      REQUIRED = %i[handler app log].freeze

      def reject_unknown(options, defaults)
        unknown = options.keys - defaults.keys - REQUIRED
        raise ArgumentError, "unknown keyword: :#{unknown.first}" unless unknown.empty?
      end

      def transport_rules(timeouts)
        check_rules(timeouts + transport_rows)
        check_buffer_body
        check_reuse_port
        raise ArgumentError, 'tls must be a Transport::Tls' unless tls.nil? || tls.is_a?(Transport::Tls)
      end

      private

      def transport_rows
        rows = [
          ['backlog', backlog, :int_at_least_one],
          ['max_connection_rate', max_connection_rate, :int_at_least_zero],
          ['client_disconnect_timeout', client_disconnect_timeout, :seconds_at_least]
        ]
        rows << ['header_timeout', header_timeout, :seconds_above] unless header_timeout.nil?
        rows << ['keep_alive_timeout', keep_alive_timeout, :seconds_at_least] unless keep_alive_timeout.nil?
        rows << ['buffer_body', buffer_body, :int_at_least_zero] unless buffer_body.nil?
        rows
      end

      def check_buffer_body
        return if buffer_body.nil? || buffer_body <= max_body

        raise ArgumentError, 'buffer_body must not exceed max_body (route limits can be larger)'
      end

      def check_reuse_port
        return unless reuse_port

        specs = Transport::Listen.resolve(listen, host, port, tls)
        return unless specs.any? { |spec| spec.kind == :tcp && spec.port.zero? }

        raise ArgumentError, 'reuse_port needs a fixed TCP port (port: 0 cannot share one port)'
      end
    end

    module Signals
      def run(grace: 30.0, signals: SIGNALS, tasks: nil)
        previous = []
        reader, writer = IO.pipe
        watch(signals, writer, previous)
        @engine.start
        code = wait_signal(reader, signals)
        restore(signals, previous)
        @log&.info("#{code} received, shutting down within #{grace}s")
        stop_all(grace, tasks)
      ensure
        release(signals, previous, reader, writer)
      end

      private

      def release(signals, previous, reader, writer)
        restore(signals, previous) unless previous.empty?
        reader&.close
        writer&.close
      end

      def wait_signal(reader, signals)
        loop do
          reader.wait_readable
          codes = reader.read_nonblock(64, exception: false)
          name = codes.is_a?(String) ? signal_in(codes, signals) : nil
          return name if name
        end
      end

      def signal_in(codes, signals)
        index = 0
        while index < codes.bytesize
          code = codes.getbyte(index) - 48
          return "SIG#{signals[code]}" if code >= 0 && code < signals.size

          index += 1
        end
        nil
      end

      def stop_all(grace, tasks)
        started = Kiln::Runtime.now
        left = shutdown(grace:)
        tasks&.shutdown(grace: [grace - (Kiln::Runtime.now - started), 0.0].max)
        left
      end

      def watch(signals, writer, previous)
        raise ArgumentError, 'signals must be a non-empty list of up to 10 names' unless signals.size.between?(1, 10)

        index = 0
        while index < signals.size
          previous << trap_signal(signals[index], writer, (48 + index).chr)
          index += 1
        end
      end

      def trap_signal(name, writer, code)
        Signal.trap(name) { writer.write_nonblock(code, exception: false) }
      end

      def restore(signals, previous)
        index = 0
        while index < previous.size
          Signal.trap(signals[index], previous[index])
          index += 1
        end
        previous.clear
      end
    end

    SHARED_DEFAULTS = {
      port: 0, host: '0.0.0.0', max_conns: 10_000, read_timeout: 5.0, request_timeout: 2.0,
      write_timeout: 10.0, max_body: 1 << 20, listen: nil, tls: nil, backlog: 1024, tcp_nodelay: true,
      max_connection_rate: 256, header_timeout: nil, keep_alive_timeout: nil, buffer_body: nil, reuse_port: false
    }.freeze
    EVENT_DEFAULTS = SHARED_DEFAULTS.merge(handlers: 0, max_streams: 1024, client_disconnect_timeout: 1.0).freeze
    BASE_DEFAULTS = SHARED_DEFAULTS.merge(kill_grace: 1.0, coop_budget: 4, shards: 1,
                                          client_disconnect_timeout: 0.5).freeze

    EventOptions = Data.define(:handler, :app, :log, :host, :port, :max_conns,
                               :read_timeout, :request_timeout, :write_timeout,
                               :max_body, :handlers, :max_streams, :listen, :tls, :backlog,
                               :tcp_nodelay, :max_connection_rate, :header_timeout,
                               :keep_alive_timeout, :client_disconnect_timeout, :buffer_body,
                               :reuse_port) do
      include Rules

      def initialize(**options)
        reject_unknown(options, EVENT_DEFAULTS)
        super(**EVENT_DEFAULTS, **options)
        transport_rules(event_rows)
      end

      private

      def event_rows
        [['max_conns', max_conns, :int_at_least_one], ['max_body', max_body, :int_at_least_zero],
         ['read_timeout', read_timeout, :seconds_above], ['request_timeout', request_timeout, :seconds_above],
         ['write_timeout', write_timeout, :seconds_above], ['handlers', handlers, :int_at_least_zero],
         ['max_streams', max_streams, :int_at_least_one]]
      end
    end

    BaseOptions = Data.define(:handler, :app, :log, :host, :port, :max_conns,
                              :read_timeout, :request_timeout, :write_timeout,
                              :kill_grace, :max_body, :coop_budget, :shards, :listen, :tls, :backlog,
                              :tcp_nodelay, :max_connection_rate, :header_timeout,
                              :keep_alive_timeout, :client_disconnect_timeout, :buffer_body,
                              :reuse_port) do
      include Rules

      def initialize(**options)
        reject_unknown(options, BASE_DEFAULTS)
        super(**BASE_DEFAULTS, **options)
        transport_rules(base_rows)
        tcp_only = Transport::Listen.resolve(listen, host, port, nil).none?(&:tls?)
        raise ArgumentError, 'tls needs the event backend' unless tls.nil? && tcp_only
      end

      private

      def base_rows
        [['max_conns', max_conns, :int_at_least_one], ['max_body', max_body, :int_at_least_zero],
         ['read_timeout', read_timeout, :seconds_above], ['request_timeout', request_timeout, :seconds_above],
         ['write_timeout', write_timeout, :seconds_above], ['kill_grace', kill_grace, :seconds_at_least],
         ['cooperative budget', coop_budget, :int_at_least_zero], ['shards', shards, :int_at_least_one]]
      end
    end

    SIGNALS = %w[INT TERM].freeze

    include Signals

    attr_reader :backend

    def initialize(handler, app, **options)
      @backend = take_backend(options)
      @log = options[:log]
      @engine = build_engine(@backend, handler, app, options)
    end

    def start
      @engine.start
      self
    end

    def port = @engine.port
    def ports = @engine.ports
    def shutdown(grace: 5.0) = @engine.shutdown(grace: grace)
    def connections = @engine.connections
    def in_flight = @engine.in_flight
    def killed = @engine.killed
    def late = @engine.late
    def free_slots = @engine.free_slots
    def handling = @engine.handling
    def handshakes = @engine.handshakes

    private

    def take_backend(options)
      if options.key?(:workers)
        raise ArgumentError, 'workers: was removed; configure Spinel parallelism with SPINEL_WORKERS'
      end

      options.key?(:backend) ? options.delete(:backend) : :event
    end

    def build_engine(backend, handler, app, options)
      case backend
      in :event
        Event.new(EventOptions.new(handler: handler, app: app, **options))
      in :base
        Base.new(BaseOptions.new(handler: handler, app: app, **options))
      else
        raise ArgumentError, 'backend must be :event or :base'
      end
    end

    private_constant :EventOptions, :BaseOptions, :SHARED_DEFAULTS, :EVENT_DEFAULTS, :BASE_DEFAULTS
  end
end
