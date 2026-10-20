module Kiln
  class Server
    module Rules
      include Check

      def transport_rules(timeouts)
        rows = [
          ['backlog', backlog, :int_at_least_one],
          ['max_connection_rate', max_connection_rate, :int_at_least_zero],
          ['client_disconnect_timeout', client_disconnect_timeout, :seconds_at_least]
        ]
        rows << ['header_timeout', header_timeout, :seconds_above] unless header_timeout.nil?
        rows << ['keep_alive_timeout', keep_alive_timeout, :seconds_at_least] unless keep_alive_timeout.nil?
        rows << ['buffer_body', buffer_body, :int_at_least_zero] unless buffer_body.nil?
        check_rules(timeouts + rows)
        if !buffer_body.nil? && buffer_body > max_body
          raise ArgumentError, 'buffer_body must not exceed max_body (route limits can be larger)'
        end
        if reuse_port && Listen.resolve(listen, host, port, tls).any? { |spec| spec.kind == :tcp && spec.port.zero? }
          raise ArgumentError, 'reuse_port needs a fixed TCP port (port: 0 cannot share one port)'
        end
        raise ArgumentError, 'tls must be a Kiln::Tls' unless tls.nil? || tls.is_a?(Tls)
      end
    end

    EventOptions = Data.define(:handler, :app, :log, :host, :port, :max_conns,
                               :read_timeout, :request_timeout, :write_timeout,
                               :max_body, :handlers, :max_streams, :listen, :tls, :backlog,
                               :tcp_nodelay, :max_connection_rate, :header_timeout,
                               :keep_alive_timeout, :client_disconnect_timeout, :buffer_body,
                               :reuse_port) do
      include Rules

      def initialize(handler:, app:, log:, port: 0, host: '0.0.0.0',
                     max_conns: 10_000, read_timeout: 5.0, request_timeout: 2.0,
                     write_timeout: 10.0, max_body: 1 << 20, handlers: 0, max_streams: 1024,
                     listen: nil, tls: nil, backlog: 1024, tcp_nodelay: true, max_connection_rate: 256,
                     header_timeout: nil, keep_alive_timeout: nil, client_disconnect_timeout: 1.0,
                     buffer_body: nil, reuse_port: false)
        super
        transport_rules([
                          ['max_conns', max_conns, :int_at_least_one],
                          ['max_body', max_body, :int_at_least_zero],
                          ['read_timeout', read_timeout, :seconds_above],
                          ['request_timeout', request_timeout, :seconds_above],
                          ['write_timeout', write_timeout, :seconds_above],
                          ['handlers', handlers, :int_at_least_zero],
                          ['max_streams', max_streams, :int_at_least_one]
                        ])
      end
    end

    BaseOptions = Data.define(:handler, :app, :log, :host, :port, :max_conns,
                              :read_timeout, :request_timeout, :write_timeout,
                              :kill_grace, :max_body, :coop_budget, :shards, :listen, :tls, :backlog,
                              :tcp_nodelay, :max_connection_rate, :header_timeout,
                              :keep_alive_timeout, :client_disconnect_timeout, :buffer_body,
                              :reuse_port) do
      include Rules

      def initialize(handler:, app:, log:, port: 0, host: '0.0.0.0',
                     max_conns: 10_000, read_timeout: 5.0, request_timeout: 2.0,
                     write_timeout: 10.0, kill_grace: 1.0, max_body: 1 << 20,
                     coop_budget: 4, shards: 1, listen: nil, tls: nil, backlog: 1024, tcp_nodelay: true,
                     max_connection_rate: 256, header_timeout: nil, keep_alive_timeout: nil,
                     client_disconnect_timeout: 0.5, buffer_body: nil, reuse_port: false)
        super
        transport_rules([
                          ['max_conns', max_conns, :int_at_least_one],
                          ['max_body', max_body, :int_at_least_zero],
                          ['read_timeout', read_timeout, :seconds_above],
                          ['request_timeout', request_timeout, :seconds_above],
                          ['write_timeout', write_timeout, :seconds_above],
                          ['kill_grace', kill_grace, :seconds_at_least],
                          ['cooperative budget', coop_budget, :int_at_least_zero],
                          ['shards', shards, :int_at_least_one]
                        ])
        tcp_only = Listen.resolve(listen, host, port, nil).none?(&:tls?)
        raise ArgumentError, 'tls needs the event backend' unless tls.nil? && tcp_only
      end
    end

    SIGNALS = %w[INT TERM].freeze

    attr_reader :backend

    def initialize(handler, app, **options)
      @backend = options.key?(:backend) ? options.delete(:backend) : :event
      if options.key?(:workers)
        raise ArgumentError, 'workers: was removed; configure Spinel parallelism with SPINEL_WORKERS'
      end

      @log = options[:log]
      @engine = build_engine(@backend, handler, app, options)
    end

    def start
      @engine.start
      self
    end

    def run(grace: 30.0, signals: SIGNALS, tasks: nil)
      previous = []
      reader, writer = IO.pipe
      watch(signals, writer, previous)
      @engine.start
      code = wait_signal(reader, signals)
      restore(signals, previous)
      previous = []
      @log&.info("#{code} received, shutting down within #{grace}s")
      stop_all(grace, tasks)
    ensure
      restore(signals, previous) unless previous.empty?
      reader&.close
      writer&.close
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

    def wait_signal(reader, signals)
      loop do
        IO.select([reader])
        codes = reader.read_nonblock(64, exception: false)
        next unless codes.is_a?(String)

        index = 0
        while index < codes.bytesize
          code = codes.getbyte(index) - 48
          return "SIG#{signals[code]}" if code >= 0 && code < signals.size

          index += 1
        end
      end
    end

    def stop_all(grace, tasks)
      started = Kiln.now
      left = shutdown(grace:)
      tasks&.shutdown(grace: [grace - (Kiln.now - started), 0.0].max)
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

    private_constant :EventOptions, :BaseOptions
  end
end
