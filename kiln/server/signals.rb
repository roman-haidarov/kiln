module Kiln
  class Server
    module Signals
      def run(grace: 30.0, signals: SIGNALS, tasks: nil)
        previous = []
        reader, writer = IO.pipe
        watch(signals, writer, previous)
        @engine.start
        code = wait_signal(reader, signals)
        restore(signals, previous)
        @log&.info("#{code} received, shutting down within #{grace}s")
        stop_all(grace, tasks)
      ensure
        release(signals, previous, reader, writer)
      end

      private

      def release(signals, previous, reader, writer)
        restore(signals, previous) unless previous.empty?
        reader&.close
        writer&.close
      end

      def wait_signal(reader, signals)
        loop do
          reader.wait_readable
          codes = reader.read_nonblock(64, exception: false)
          name = codes.is_a?(String) ? signal_in(codes, signals) : nil
          return name if name
        end
      end

      def signal_in(codes, signals)
        index = 0
        while index < codes.bytesize
          code = codes.getbyte(index) - 48
          return "SIG#{signals[code]}" if code >= 0 && code < signals.size

          index += 1
        end
        nil
      end

      def stop_all(grace, tasks)
        started = Kiln::Runtime.now
        left = shutdown(grace:)
        tasks&.shutdown(grace: [grace - (Kiln::Runtime.now - started), 0.0].max)
        left
      end

      def watch(signals, writer, previous)
        raise ArgumentError, 'signals must be a non-empty list of up to 10 names' unless signals.size.between?(1, 10)

        index = 0
        while index < signals.size
          previous << trap_signal(signals[index], writer, (48 + index).chr)
          index += 1
        end
      end

      def trap_signal(name, writer, code)
        Signal.trap(name) { writer.write_nonblock(code, exception: false) }
      end

      def restore(signals, previous)
        index = 0
        while index < previous.size
          Signal.trap(signals[index], previous[index])
          index += 1
        end
        previous.clear
      end
    end

  end
end
