require 'kiln/server/settings'
require 'kiln/server/signals'

module Kiln
  class Server
    SIGNALS = %w[INT TERM].freeze

    include Signals

    attr_reader :backend

    def initialize(handler, **options)
      @backend = take_backend(options)
      @log = Settings.log(options[:log])
      @engine = build_engine(@backend, handler, options)
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

    def build_engine(backend, handler, options)
      options[:host] = Settings::SHARED[:host] unless options.key?(:host)
      case backend
      in :event then Event.new(handler, **options)
      in :base then Base.new(handler, **options)
      else raise ArgumentError, 'backend must be :event or :base'
      end
    end

    private_constant :Settings
  end
end
