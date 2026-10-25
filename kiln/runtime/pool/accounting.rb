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

  end
end
