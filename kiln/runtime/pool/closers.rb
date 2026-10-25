module Kiln
  module Runtime
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

  end
end
