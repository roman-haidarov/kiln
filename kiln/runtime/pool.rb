module Kiln
  module Runtime
    module PoolAccounting
      class << self
        def add_quarantine(list, closer, token)
          closer.quarantine = token if closer
          list << token
        end

        def release_one?(list, closer)
          !list.delete(closer.quarantine).nil?
        end

        def release_all(list)
          list.clear
        end
      end
    end

    module PoolStats
      def available = safe_lock { @size - @open + @idle.size }
      def idle = safe_lock { @idle.size }
      def checked_out = safe_lock { @out }
      def closing = safe_lock { @closing }
      def close_failures = safe_lock { @close_failures }
      def close_abandoned = safe_lock { @close_abandoned }
      def quarantined = safe_lock { @quarantined }
      def shutdown_state = @lock.synchronize { @state }

      def consistent?
        safe_lock do
          @out >= 0 && @closing >= 0 && @quarantined >= 0 && @open <= @size &&
            @open == @idle.size + @out + @closing + @quarantined
        end
      end

      def release_quarantined(count = -1)
        check_rules([['pool quarantine count', count, :int_from_minus_one]])
        released = safe_lock { take_quarantined(count) }
        wake_idle if released.positive?
        released
      end

      private

      def safe_lock
        @lock.synchronize do
          drain_returns
          yield
        end
      end

      def take_quarantined(count)
        taken = count.negative? || count > @quarantined ? @quarantined : count
        @quarantines.shift(taken)
        @quarantined -= taken
        @open -= taken
        taken
      end
    end

    module PoolLeases
      Lease = Struct.new(:resource, :held, :thread)

      def acquire(timeout: 1.0)
        held = new_hold(timeout)
        checkout(held)
        resource = held.entry.resource
        @lock.synchronize { @leases << Lease.new(resource, held, Thread.current) }
        resource
      end

      def release(resource, error = nil)
        held = take_lease(resource).held
        held.keep = keep_entry?(held.entry, error)
        settle_checkout(held)
        flush_shutdown if @state != :open
        nil
      end

      private

      def take_lease(resource)
        @lock.synchronize do
          index = lease_index(resource)
          raise ArgumentError, 'resource was not acquired' if index.nil?

          owner = @leases[index].thread
          raise ThreadError, 'connection released from another thread' unless owner.equal?(Thread.current)

          @leases.delete_at(index)
        end
      end

      def lease_index(resource)
        index = 0
        while index < @leases.size
          return index if @leases[index].resource.equal?(resource)

          index += 1
        end
        nil
      end
    end

    module PoolCheckout
      Held = Struct.new(:entry, :granted, :keep, :quarantine, :checked, :limit, :by_deadline, :error)

      private

      def new_hold(timeout)
        check_rules([['pool timeout', timeout, :seconds_above]])
        limit, by_deadline = wait_budget(timeout)
        Held.new(nil, false, false, false, false, limit, by_deadline, nil)
      end

      def wait_budget(timeout)
        left = Kiln::Runtime.remaining
        return [Kiln::Runtime.now + timeout, false] if left.nil?
        raise DeadlineExceeded, 'deadline exceeded' if left <= 0
        return [Kiln::Runtime.now + timeout, false] if left > timeout

        [Kiln::Runtime.now + left, true]
      end

      def checkout(held)
        loop do
          reserve_slot(held)
          break unless discard_stale?(held)
        end
        held.entry ||= build_entry(held)
        held.granted = true
        held.checked = true
        held.entry
      end

      def reserve_slot(held)
        until held.granted
          try_reserve(held)
          break if held.granted || !await_slot?(held.limit)
        end
        return if held.granted
        raise DeadlineExceeded, 'deadline exceeded' if held.by_deadline

        raise PoolTimeout, 'pool timeout'
      end

      def try_reserve(held)
        @lock.synchronize do
          drain_returns
          raise IOError, 'pool is closing' if @state != :open

          take_slot(held) if Kiln::Runtime.now < held.limit
          wake_idle if held.granted && (!@idle.empty? || @open < @size)
        end
      end

      def take_slot(held)
        entry = @idle.pop
        return if entry.nil? && @open >= @size

        @open += 1 if entry.nil?
        @out += 1
        held.entry = entry
        held.granted = true
      end

      def await_slot?(limit)
        rest = limit - Kiln::Runtime.now
        return false if rest <= 0

        @wake.pop(timeout: [rest, 0.05].min)
        true
      end

      def discard_stale?(held)
        entry = held.entry
        return false unless entry && (@max_lifetime.positive? || @validate) && stale_entry?(entry)

        held.entry = nil
        held.quarantine = true
        closed = closed_cleanly?(entry)
        held.quarantine = false
        return false if closed

        held.granted = false
        @events << Pool::QUARANTINED
        true
      end

      def build_entry(held)
        entry = nil
        begin
          resource = @factory.call
          raise ArgumentError, 'pool factory returned no resource' unless resource

          entry = Pool::Entry.new(resource, Kiln::Runtime.now)
        ensure
          discard_slot(held) unless entry
        end
      end

      def discard_slot(held)
        @events << Pool::DISCARDED
        wake_idle
        held.granted = false
      end
    end

    module PoolHealth
      private

      def held_failed(held, error)
        held.error = error
        held.keep = keep_entry?(held.entry, error) if held.checked
      end

      def keep_entry?(entry, err)
        return false if lifetime_spent?(entry)

        err.nil? || !discard_error?(err)
      end

      def discard_error?(err)
        @discard.call(err)
      rescue StandardError
        true
      end

      def lifetime_spent?(entry)
        @max_lifetime.positive? && Kiln::Runtime.now - entry.born >= @max_lifetime
      end

      def stale_entry?(entry)
        return true if lifetime_spent?(entry)
        return false unless @validate

        !@validate.call(entry.resource)
      rescue StandardError
        true
      end

      def closed_cleanly?(entry)
        @close&.call(entry.resource)
        true
      rescue StandardError
        false
      end
    end

    module PoolReturns
      private

      def settle_checkout(held)
        return unless held.granted

        event = return_event(held)
        if event.nil?
          close_returned(held.entry)
        else
          @events << event
        end
        wake_idle
      end

      def return_event(held)
        return held.entry if held.keep && @state == :open
        return Pool::QUARANTINED if held.quarantine
        return Pool::DISCARDED if held.entry.nil?

        nil
      end

      def close_returned(entry)
        closer = Pool::Close.new(Thread.current, :new)
        @events << [:start, closer]
        failed = true
        begin
          failed = !closed_cleanly?(entry)
        ensure
          @events << [failed ? :failure : :success, closer]
        end
      end

      def wake_idle
        return unless @wake.empty?

        @wake.push(true, true)
      rescue ThreadError
        nil
      end

      def drain_returns
        apply_return(@events.pop) until @events.empty?
        sweep_closers
        release_failed_quarantine if @release_failed && @quarantined.positive?
      end

      def release_failed_quarantine
        PoolAccounting.release_all(@quarantines)
        @open -= @quarantined
        @quarantines.clear
        @quarantined = 0
      end

      def apply_return(event)
        return apply_closer(event[0], event[1]) unless event.is_a?(Pool::Entry)

        @out -= 1
        if event.equal?(Pool::QUARANTINED)
          note_quarantine(nil)
          @close_failures += 1
        elsif event.equal?(Pool::DISCARDED)
          @open -= 1
        else
          park_entry(event)
        end
      end

      def park_entry(entry)
        if @state == :open
          @idle.push(entry)
        else
          @shutdown_queue << entry
          @closing += 1
        end
      end
    end

    module PoolClosers
      private

      def apply_closer(kind, closer)
        return start_closer(closer) if kind == :start
        return unless %i[closing abandoned].include?(closer.state)

        success = kind == :success
        if closer.state == :closing
          finish_closer(closer, success)
        else
          late_closer(closer, success)
        end
        closer.state = success ? :success : :failed
      end

      def start_closer(closer)
        return unless closer.state == :new

        closer.state = :closing
        @out -= 1
        @closing += 1
        @closers << closer
      end

      def finish_closer(closer, success)
        @closers.delete_if { |tracked| tracked.equal?(closer) }
        @closing -= 1
        if success
          @open -= 1
        else
          note_quarantine(closer)
          @close_failures += 1
        end
      end

      def late_closer(closer, success)
        if success
          release_closer(closer)
        else
          @close_failures += 1
        end
      end

      def release_closer(closer)
        return unless PoolAccounting.release_one?(@quarantines, closer)

        @quarantined -= 1
        @open -= 1
      end

      def note_quarantine(closer)
        @quarantine_seq += 1
        PoolAccounting.add_quarantine(@quarantines, closer, @quarantine_seq)
        @quarantined += 1
      end

      def sweep_closers
        idx = 0
        while idx < @closers.size
          closer = @closers[idx]
          if closer.thread.alive?
            idx += 1
          else
            @closers.delete_at(idx)
            abandon_closer(closer)
          end
        end
      end

      def abandon_closer(closer)
        closer.state = :abandoned
        @closing -= 1
        note_quarantine(closer)
        @close_abandoned += 1
      end
    end

    module PoolShutdown
      def shutdown(timeout: 5.0)
        raise ArgumentError, 'shutdown timeout' unless timeout.is_a?(Numeric) && timeout >= 0

        begin_shutdown
        deadline = Kiln::Runtime.now + timeout
        loop do
          flush_shutdown
          left = shutdown_left
          return left if left.zero? || Kiln::Runtime.now >= deadline

          Kernel.sleep(0.01)
        end
      end

      private

      def begin_shutdown
        @lock.synchronize { @state = :closing if @state == :open }
        wake_idle
      end

      def shutdown_left
        @lock.synchronize do
          drain_returns
          @state = :closed if @open.zero?
          @open
        end
      end

      def flush_shutdown
        loop do
          entry = next_shutdown_entry
          break unless entry

          finish_shutdown_entry(closed_cleanly?(entry))
        end
      end

      def next_shutdown_entry
        @lock.synchronize do
          drain_returns
          queue_idle_for_shutdown if @state != :open
          @shutdown_queue.shift
        end
      end

      def queue_idle_for_shutdown
        until @idle.empty?
          @shutdown_queue << @idle.pop
          @closing += 1
        end
      end

      def finish_shutdown_entry(success)
        @lock.synchronize do
          @closing -= 1
          if success
            @open -= 1
          else
            note_quarantine(nil)
            @close_failures += 1
          end
        end
      end
    end

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
