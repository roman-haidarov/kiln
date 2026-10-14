module Kiln
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

  class Pool
    include Check

    DISCARD = ->(err) { err.is_a?(IOError) || err.is_a?(SystemCallError) || err.is_a?(DeadlineExceeded) }
    Entry = Struct.new(:resource, :born)
    DISCARDED = Entry.new(nil, 0.0)
    QUARANTINED = Object.new
    HELD_ENTRY = 0
    HELD_GRANTED = 1
    HELD_KEEP = 2
    HELD_QUARANTINE = 3
    Close = Struct.new(:thread, :state, :quarantine)

    def initialize(size, discard: DISCARD, close: nil, validate: nil, max_lifetime: 0.0,
                   on_close_failure: :quarantine, &factory)
      raise ArgumentError, 'pool factory required' unless factory

      raise ArgumentError, 'pool on_close_failure' unless on_close_failure in :quarantine | :release

      check_rules([
                    ['pool size', size, :int_at_least_one],
                    ['pool max_lifetime', max_lifetime, :seconds_at_least]
                  ])

      @lock = Mutex.new
      @events = Queue.new
      @wake = SizedQueue.new(1)
      @factory = factory
      @discard = discard
      @close = close
      @validate = validate
      @max_lifetime = max_lifetime.to_f
      @size = size
      @quarantine_seq = 0
      @release_failed = on_close_failure == :release

      @idle = []
      @closers = []
      @quarantines = []
      @open = 0
      @out = 0
      @closing = 0
      @quarantined = 0
      @close_failures = 0
      @close_abandoned = 0
    end

    def with(timeout: 1.0)
      self.check_rules([['pool timeout', timeout, :seconds_above]])
      limit, by_deadline = self.wait_budget(timeout)
      held = [nil, false, false, false]
      err = nil
      result = nil
      begin
        self.checkout(limit, by_deadline, held)
        entry = held[HELD_ENTRY]
        begin
          result = yield entry.resource
        rescue StandardError => caught
          err = caught
        end
        held[HELD_KEEP] = self.keep_entry?(entry, err)
      ensure
        self.settle_checkout(held)
      end
      raise err if err

      result
    end

    def available
      safe_lock { @size - @open + @idle.size }
    end

    def idle
      safe_lock { @idle.size }
    end

    def checked_out
      safe_lock { @out }
    end

    def closing
      safe_lock { @closing }
    end

    def close_failures
      safe_lock { @close_failures }
    end

    def close_abandoned
      safe_lock { @close_abandoned }
    end

    def quarantined
      safe_lock { @quarantined }
    end

    attr_reader :size

    def consistent?
      safe_lock do
        @out >= 0 && @closing >= 0 && @quarantined >= 0 && @open <= @size &&
          @open == @idle.size + @out + @closing + @quarantined
      end
    end

    def release_quarantined(count = -1)
      check_rules([['pool quarantine count', count, :int_from_minus_one]])
      released = safe_lock do
        taken = count.negative? || count > @quarantined ? @quarantined : count
        @quarantines.shift(taken)
        @quarantined -= taken
        @open -= taken
        taken
      end
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

    def wait_budget(timeout)
      wait = timeout
      by_deadline = false
      left = Kiln.remaining
      if left
        raise DeadlineExceeded, 'deadline exceeded' if left <= 0

        if left <= wait
          wait = left
          by_deadline = true
        end
      end
      [Kiln.now + wait, by_deadline]
    end

    def checkout(limit, by_deadline, held)
      entry = nil
      granted = false
      quarantine = false
      acquiring = true
      while acquiring
        acquiring = false
        until granted
          @lock.synchronize do
            self.drain_returns
            if Kiln.now < limit
              entry = @idle.pop
              if entry
                @out += 1
                granted = true
              elsif @open < @size
                @open += 1
                @out += 1
                granted = true
              end
            end
            self.wake_idle if granted && (!@idle.empty? || @open < @size)
          end
          held[HELD_ENTRY] = entry
          held[HELD_GRANTED] = granted
          held[HELD_QUARANTINE] = quarantine
          break if granted

          rest = limit - Kiln.now
          break if rest <= 0

          @wake.pop(timeout: rest < 0.05 ? rest : 0.05)
        end
        unless granted
          raise DeadlineExceeded, 'deadline exceeded' if by_deadline

          raise PoolTimeout, 'pool timeout'
        end
        if entry && (@max_lifetime.positive? || @validate) && self.stale_entry?(entry)
          stale_entry = entry
          quarantine = true
          entry = nil
          held[HELD_ENTRY] = nil
          held[HELD_QUARANTINE] = true
          unless self.close_stale_entry?(stale_entry)
            granted = false
            quarantine = false
            held[HELD_GRANTED] = false
            held[HELD_QUARANTINE] = false
            @events << QUARANTINED
            acquiring = true
          end
          quarantine = false
          held[HELD_QUARANTINE] = false
        end
      end
      unless entry
        resource = @factory.call
        raise ArgumentError, 'pool factory returned no resource' unless resource

        entry = Entry.new(resource, Kiln.now)
      end
      held[HELD_ENTRY] = entry
      held[HELD_GRANTED] = true
      held[HELD_QUARANTINE] = false
      entry
    end

    def keep_entry?(entry, err)
      healthy = err.nil? || !(begin
        @discard.call(err)
      rescue StandardError
        true
      end)
      return false if self.lifetime_spent?(entry)

      healthy
    end

    def settle_checkout(held)
      return unless held[HELD_GRANTED]

      entry = held[HELD_ENTRY]
      if held[HELD_KEEP]
        @events << entry
      elsif held[HELD_QUARANTINE]
        @events << QUARANTINED
      elsif entry.nil?
        @events << DISCARDED
      else
        closer = Close.new(Thread.current, :new)
        @events << [:start, closer]
        failed = true
        begin
          begin
            @close&.call(entry.resource)
            failed = false
          rescue StandardError
            nil
          end
        ensure
          @events << [failed ? :failure : :success, closer]
        end
      end
      wake_idle
    end

    def wake_idle
      return unless @wake.empty?

      @wake.push(true, true)
    rescue ThreadError
      nil
    end

    def lifetime_spent?(entry)
      @max_lifetime.positive? && Kiln.now - entry.born >= @max_lifetime
    end

    def stale_entry?(entry)
      return true if self.lifetime_spent?(entry)
      return false unless @validate

      begin
        !@validate.call(entry.resource)
      rescue StandardError
        true
      end
    end

    def close_stale_entry?(entry)
      @close&.call(entry.resource)
      true
    rescue StandardError
      false
    end

    def drain_returns
      until @events.empty?
        apply_return(@events.pop)
      end
      sweep_closers
      return unless @release_failed && @quarantined.positive?

      PoolAccounting.release_all(@quarantines)
      @open -= @quarantined
      @quarantines.clear
      @quarantined = 0
    end

    def apply_return(event)
      if event.is_a?(Entry)
        if event.equal?(DISCARDED)
          @open -= 1
        else
          @idle.push(event)
        end
        @out -= 1
      elsif event.equal?(QUARANTINED)
        @out -= 1
        note_quarantine(nil)
        @close_failures += 1
      else
        apply_closer(event[0], event[1])
      end
    end

    def apply_closer(kind, value)
      state = value.state
      success = kind == :success
      if kind == :start
        return unless state == :new

        value.state = :closing
        @out -= 1
        @closing += 1
        @closers << value
        return
      end
      closing = state == :closing
      return unless closing || state == :abandoned

      if closing
        @closers.delete_if { |tracked| tracked.equal?(value) }
        @closing -= 1
        if success
          @open -= 1
        else
          note_quarantine(value)
          @close_failures += 1
        end
      elsif success
        if PoolAccounting.release_one?(@quarantines, value)
          @quarantined -= 1
          @open -= 1
        end
      else
        @close_failures += 1
      end
      value.state = success ? :success : :failed
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
          closer.state = :abandoned
          @closing -= 1
          note_quarantine(closer)
          @close_abandoned += 1
        end
      end
    end
  end
end

require 'kiln/cpu_pool'
