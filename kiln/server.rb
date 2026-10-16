module Kiln
  class Server
    EventOptions = Data.define(:handler, :app, :log, :host, :port, :max_conns,
                               :read_timeout, :request_timeout, :write_timeout,
                               :max_body, :handlers, :max_streams) do
      include Check

      def initialize(handler:, app:, log:, port:, host: '0.0.0.0',
                     max_conns: 10_000, read_timeout: 5.0, request_timeout: 2.0,
                     write_timeout: 10.0, max_body: 1 << 20, handlers: 0, max_streams: 1024)
        check_rules([
                      ['max_conns', max_conns, :int_at_least_one],
                      ['max_body', max_body, :int_at_least_zero],
                      ['read_timeout', read_timeout, :seconds_above],
                      ['request_timeout', request_timeout, :seconds_above],
                      ['write_timeout', write_timeout, :seconds_above],
                      ['handlers', handlers, :int_at_least_zero],
                      ['max_streams', max_streams, :int_at_least_one]
                    ])
        super
      end
    end

    BaseOptions = Data.define(:handler, :app, :log, :host, :port, :max_conns,
                              :read_timeout, :request_timeout, :write_timeout,
                              :kill_grace, :max_body, :coop_budget, :shards) do
      include Check

      def initialize(handler:, app:, log:, port:, host: '0.0.0.0',
                     max_conns: 10_000, read_timeout: 5.0, request_timeout: 2.0,
                     write_timeout: 10.0, kill_grace: 1.0, max_body: 1 << 20,
                     coop_budget: 4, shards: 1)
        check_rules([
                      ['max_conns', max_conns, :int_at_least_one],
                      ['max_body', max_body, :int_at_least_zero],
                      ['read_timeout', read_timeout, :seconds_above],
                      ['request_timeout', request_timeout, :seconds_above],
                      ['write_timeout', write_timeout, :seconds_above],
                      ['kill_grace', kill_grace, :seconds_at_least],
                      ['cooperative budget', coop_budget, :int_at_least_zero],
                      ['shards', shards, :int_at_least_one]
                    ])
        super
      end
    end

    SIGNALS = %w[INT TERM].freeze

    attr_reader :backend

    def initialize(handler, app, **options)
      @backend = options.key?(:backend) ? options.delete(:backend) : :event
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
      start
      code = reader.read(1)
      restore(signals, previous)
      previous = []
      @log&.info("SIG#{signals[code.to_s.ord - 48]} received, shutting down within #{grace}s")
      stop_all(grace, tasks)
    ensure
      restore(signals, previous) unless previous.empty?
      reader&.close
      writer&.close
    end

    def port = @engine.port
    def shutdown(grace: 5.0) = @engine.shutdown(grace: grace)
    def connections = @engine.connections

    def in_flight = @engine.in_flight
    def killed = @engine.killed
    def late = @engine.late
    def free_slots = @engine.free_slots
    def handling = @engine.handling

    private

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
