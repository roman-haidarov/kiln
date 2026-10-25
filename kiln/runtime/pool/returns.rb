module Kiln
  module Runtime
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

  end
end
