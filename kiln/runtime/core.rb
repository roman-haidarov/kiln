require 'kiln/runtime/errors'

module Kiln
  module Runtime
    class << self
      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      def deadline
        stamp = Thread.current[:kiln_deadline]
        stamp.nil? ? 0.0 : stamp
      end

      def remaining
        stamp = deadline
        stamp.positive? ? stamp - now : nil
      end

      def check!
        left = remaining
        raise DeadlineExceeded, 'deadline exceeded' if left && left <= 0
      end

      def pause(sec)
        left = remaining
        if left && left < sec
          Kernel.sleep(left) if left.positive?
          raise DeadlineExceeded, 'deadline exceeded'
        end
        Kernel.sleep(sec)
      end

      def client_gone?
        fd = Thread.current[:kiln_fd]
        return false if fd.nil?

        Kiln::HTTP::Native.kiln_peer_closed(fd) == 1
      end

      def pop(queue)
        left = remaining
        return queue.pop if left.nil?
        raise DeadlineExceeded, 'deadline exceeded' unless left.positive?

        value = queue.pop(timeout: left)
        raise DeadlineExceeded, 'deadline exceeded' if value.nil? && Kiln::Runtime.now >= deadline

        value
      end

      def check_client!
        raise ClientGone, 'client disconnected' if client_gone?
      end

      def unwind?(error)
        error.is_a?(SystemExit) || error.is_a?(SignalException)
      end

      def timeout_reply(err)
        runtime_reply(err) || http_reply(err)
      end

      def runtime_reply(err)
        return ["deadline exceeded\n", 504] if err.is_a?(Kiln::Runtime::DeadlineExceeded)
        return ["busy\n", 503] if err.is_a?(Kiln::Runtime::PoolTimeout)

        nil
      end

      def http_reply(err)
        return ["#{err.message}\n", 400] if err.is_a?(Kiln::HTTP::BadRequest)
        return ["payload too large\n", 413] if err.is_a?(Kiln::HTTP::PayloadTooLarge)
        return ["request timeout\n", 408] if err.is_a?(Kiln::HTTP::RequestTimeout)
        return ["headers too large\n", 431] if err.is_a?(Kiln::HTTP::TrailersTooLarge)
        return ["#{err.message}\n", 415] if err.is_a?(Kiln::HTTP::UnsupportedMediaType)

        nil
      end

      def dispatch_failure(log, ctx, err)
        reply = timeout_reply(err)
        return Kiln::Observability.fail_request(log, ctx, err) unless reply

        apply_reply(ctx, reply)
      end

      def apply_reply(ctx, reply) = ctx.res.text(reply[0], status: reply[1])

      def first_port(ports)
        index = 0
        while index < ports.size
          port = ports[index]
          return port if port.positive?

          index += 1
        end
        0
      end
    end
  end
end
