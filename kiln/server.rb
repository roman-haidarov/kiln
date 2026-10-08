module Kiln
  class Server
    EventOptions = Data.define(:handler, :app, :log, :host, :port, :max_conns,
                               :read_timeout, :request_timeout, :max_body, :handlers) do
      include Check

      def initialize(handler:, app:, log:, port:, host: '0.0.0.0',
                     max_conns: 10_000, read_timeout: 5.0, request_timeout: 2.0,
                     max_body: 1 << 20, handlers: 0)
        check_rules([
                      ['max_conns', max_conns, :int_at_least_one],
                      ['max_body', max_body, :int_at_least_zero],
                      ['read_timeout', read_timeout, :seconds_above],
                      ['request_timeout', request_timeout, :seconds_above],
                      ['handlers', handlers, :int_at_least_zero]
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

    attr_reader :backend

    def initialize(handler, app, **options)
      @backend = options.key?(:backend) ? options.delete(:backend) : :event
      @engine = build_engine(@backend, handler, app, options)
    end

    def start
      @engine.start
      self
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
