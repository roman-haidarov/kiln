module Kiln
  module PoolAccounting
    class << self
      def add_quarantine(list, closer, token)
        closer.quarantine = token if closer
        list << token
      end

      def release_one(list, closer)
        !list.delete(closer.quarantine).nil?
      end

      def release_all(list)
        list.clear
      end
    end
  end

  class Pool
    DISCARD = ->(e) { e.is_a?(IOError) || e.is_a?(SystemCallError) || e.is_a?(DeadlineExceeded) }
    Entry = Struct.new(:resource, :born)
    DISCARDED = Entry.new(nil, 0.0)
    QUARANTINED = Object.new
    Close = Struct.new(:thread, :state, :quarantine)

    def initialize(size, discard: DISCARD, close: nil, validate: nil, max_lifetime: 0.0,
                   on_close_failure: :quarantine, &factory)
      raise ArgumentError, "pool factory required" unless factory
      raise ArgumentError, "pool on_close_failure" unless on_close_failure == :quarantine || on_close_failure == :release
      raise ArgumentError, "pool size" unless size.is_a?(Integer) && size > 0
      unless (max_lifetime.is_a?(Integer) || max_lifetime.is_a?(Float)) && max_lifetime.finite? && max_lifetime >= 0
        raise ArgumentError, "pool max_lifetime"
      end

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
      @open, @out, @closing, @quarantined, @close_failures, @close_abandoned = 0, 0, 0, 0, 0, 0
    end

    def with(timeout: 1.0)
      unless (timeout.is_a?(Integer) || timeout.is_a?(Float)) && timeout.finite? && timeout > 0
        raise ArgumentError, "pool timeout"
      end
      wait = timeout
      by_deadline = false
      left = Kiln.remaining
      if left
        raise DeadlineExceeded, "deadline exceeded" if left <= 0
        if left <= wait
          wait = left
          by_deadline = true
        end
      end
      limit = Kiln.now + wait

      entry, err, result = nil, nil, nil
      granted, keep, quarantine = false, false, false

      acquiring = true
      begin
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
              if granted && (!@idle.empty? || @open < @size) && @wake.empty?
                begin
                  @wake.push(true, true)
                rescue ThreadError
                  nil
                end
              end
            end
            break if granted
            rest = limit - Kiln.now
            break if rest <= 0
            @wake.pop(timeout: rest < 0.05 ? rest : 0.05)
          end
          unless granted
            raise DeadlineExceeded, "deadline exceeded" if by_deadline
            raise PoolTimeout, "pool timeout"
          end
          if entry && (@max_lifetime > 0 || @validate) && self.stale_entry?(entry)
            stale_entry = entry
            quarantine = true
            entry = nil
            unless self.close_stale_entry(stale_entry)
              granted = false
              @events << QUARANTINED
              acquiring = true
            end
            quarantine = false
          end
        end
        unless entry
          resource = @factory.call
          raise ArgumentError, "pool factory returned no resource" unless resource
          entry = Entry.new(resource, Kiln.now)
        end
        begin
          result = yield entry.resource
        rescue StandardError => e
          err = e
        end
        healthy = err.nil? || !(begin
                                  @discard.call(err)
                                rescue StandardError
                                  true
                                end)
        healthy = false if @max_lifetime > 0 && Kiln.now - entry.born >= @max_lifetime
        keep = healthy
      ensure
        if granted
          if keep
            @events << entry
          elsif quarantine
            @events << QUARANTINED
          elsif entry.nil?
            @events << DISCARDED
          else
            closer = Close.new(Thread.current, :new)
            @events << [:start, closer]
            failed = true
            begin
              begin
                @close.call(entry.resource) if @close
                failed = false
              rescue StandardError
                nil
              end
            ensure
              @events << [failed ? :failure : :success, closer]
            end
          end
          if @wake.empty?
            begin
              @wake.push(true, true)
            rescue ThreadError
              nil
            end
          end
        end
      end
      raise err if err
      result
    end

    def available = @lock.synchronize { drain_returns; @size - @open + @idle.size }
    def idle = @lock.synchronize { drain_returns; @idle.size }
    def checked_out = @lock.synchronize { drain_returns; @out }
    def closing = @lock.synchronize { drain_returns; @closing }
    def close_failures = @lock.synchronize { drain_returns; @close_failures }
    def close_abandoned = @lock.synchronize { drain_returns; @close_abandoned }
    def quarantined = @lock.synchronize { drain_returns; @quarantined }
    def size = @size

    def consistent?
      @lock.synchronize do
        drain_returns
        @out >= 0 && @closing >= 0 && @quarantined >= 0 && @open <= @size && @open == @idle.size + @out + @closing + @quarantined
      end
    end

    def release_quarantined(count = -1)
      unless count.is_a?(Integer) && count >= -1
        raise ArgumentError, "pool quarantine count"
      end
      released = @lock.synchronize do
        drain_returns
        n = count < 0 || count > @quarantined ? @quarantined : count
        @quarantines.shift(n)
        @quarantined -= n
        @open -= n
        n
      end
      if released > 0 && @wake.empty?
        begin
          @wake.push(true, true)
        rescue ThreadError
          nil
        end
      end
      released
    end

    private

    def stale_entry?(entry)
      return true if @max_lifetime > 0 && Kiln.now - entry.born >= @max_lifetime
      return false unless @validate
      begin
        !@validate.call(entry.resource)
      rescue StandardError
        true
      end
    end

    def close_stale_entry(entry)
      @close.call(entry.resource) if @close
      true
    rescue StandardError
      false
    end

    def drain_returns
      until @events.empty?
        event = @events.pop
        if event.is_a?(Entry)
          if event.equal?(DISCARDED)
            @open -= 1
          else
            @idle.push(event)
          end
          @out -= 1
        elsif event.equal?(QUARANTINED)
          @out -= 1
          @quarantine_seq += 1
          PoolAccounting.add_quarantine(@quarantines, nil, @quarantine_seq)
          @quarantined += 1
          @close_failures += 1
        else
          kind = event[0]
          value = event[1]
          if kind == :start
            if value.state == :new
              value.state = :closing
              @out -= 1
              @closing += 1
              @closers << value
            end
          elsif value.state == :closing
            @closers.delete_if { |tracked| tracked.equal?(value) }
            @closing -= 1
            if kind == :success
              @open -= 1
              value.state = :success
            else
              @quarantine_seq += 1
              PoolAccounting.add_quarantine(@quarantines, value, @quarantine_seq)
              @quarantined += 1
              @close_failures += 1
              value.state = :failed
            end
          elsif value.state == :abandoned
            if kind == :success
              if PoolAccounting.release_one(@quarantines, value)
                @quarantined -= 1
                @open -= 1
              end
              value.state = :success
            else
              @close_failures += 1
              value.state = :failed
            end
          end
        end
      end
      idx = 0
      while idx < @closers.size
        closer = @closers[idx]
        if closer.thread.alive?
          idx += 1
        else
          @closers.delete_at(idx)
          closer.state = :abandoned
          @closing -= 1
          @quarantine_seq += 1
          PoolAccounting.add_quarantine(@quarantines, closer, @quarantine_seq)
          @quarantined += 1
          @close_abandoned += 1
        end
      end
      if @release_failed && @quarantined > 0
        PoolAccounting.release_all(@quarantines)
        @open -= @quarantined
        @quarantines.clear
        @quarantined = 0
      end
      true
    end
  end
end

require "kiln/cpu_pool"
