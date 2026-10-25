module Kiln
  module Runtime
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

  end
end
