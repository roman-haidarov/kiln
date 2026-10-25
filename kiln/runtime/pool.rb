require 'kiln/runtime/pool/accounting'
require 'kiln/runtime/pool/leases'
require 'kiln/runtime/pool/checkout'
require 'kiln/runtime/pool/returns'
require 'kiln/runtime/pool/closers'
require 'kiln/runtime/pool/shutdown'

module Kiln
  module Runtime
    class Pool
      include Check
      include PoolStats
      include PoolLeases
      include PoolCheckout
      include PoolHealth
      include PoolReturns
      include PoolClosers
      include PoolShutdown

      DISCARD = ->(err) { err.is_a?(IOError) || err.is_a?(SystemCallError) || err.is_a?(DeadlineExceeded) }
      Entry = Struct.new(:resource, :born)
      DISCARDED = Entry.new(nil, 0.0)
      QUARANTINED = Entry.new(nil, -1.0)
      Close = Struct.new(:thread, :state, :quarantine)
      LIMIT_KEYS = %i[max_lifetime on_close_failure].freeze

      attr_reader :size

      def initialize(size, discard: DISCARD, close: nil, validate: nil, **limits, &factory)
        raise ArgumentError, 'pool factory required' unless factory

        @size = size
        init_limits(limits)
        init_hooks(factory, discard, close, validate)
        init_state
      end

      def with(timeout: 1.0)
        held = new_hold(timeout)
        begin
          result = yield checkout(held).resource
          held.keep = keep_entry?(held.entry, nil)
        rescue StandardError => e
          held_failed(held, e)
        ensure
          settle_checkout(held)
        end
        held.error ? raise(held.error) : result
      end

      private

      def init_limits(limits)
        max_lifetime, on_close_failure = pool_limits(limits)
        check_rules([['pool size', @size, :int_at_least_one], ['pool max_lifetime', max_lifetime, :seconds_at_least]])
        @max_lifetime = max_lifetime.to_f
        @release_failed = on_close_failure == :release
      end

      def pool_limits(limits)
        unknown = limits.keys - LIMIT_KEYS
        raise ArgumentError, "unknown pool option #{unknown.first}" unless unknown.empty?

        on_close_failure = limits.fetch(:on_close_failure, :quarantine)
        raise ArgumentError, 'pool on_close_failure' unless on_close_failure in :quarantine | :release

        [limits.fetch(:max_lifetime, 0.0), on_close_failure]
      end

      def init_hooks(factory, discard, close, validate)
        @factory = factory
        @discard = discard
        @close = close
        @validate = validate
      end

      def init_state
        @lock = Mutex.new
        @events = Queue.new
        @wake = SizedQueue.new(1)
        @quarantine_seq = 0
        @state = :open
        @leases = []
        init_lists
        init_counters
      end

      def init_lists
        @idle = []
        @closers = []
        @quarantines = []
        @shutdown_queue = []
      end

      def init_counters
        @open = 0
        @out = 0
        @closing = 0
        @quarantined = 0
        @close_failures = 0
        @close_abandoned = 0
      end
    end
  end
end
