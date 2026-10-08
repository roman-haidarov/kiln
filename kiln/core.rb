module Kiln
  class DeadlineExceeded < StandardError; end
  class PoolTimeout < StandardError; end
  class WorkerLost < StandardError; end
  class ClientGone < StandardError; end

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

      HttpNative.kiln_peer_closed(fd) == 1
    end

    def check_client!
      raise ClientGone, 'client disconnected' if client_gone?
    end

    def unwind?(error)
      error.is_a?(SystemExit) || error.is_a?(SignalException)
    end

    def timeout_reply(err)
      case err
      in DeadlineExceeded
        ["deadline exceeded\n", 504]
      in PoolTimeout
        ["busy\n", 503]
      else
        nil
      end
    end

    def dispatch_failure(log, ctx, err)
      reply = timeout_reply(err)
      return fail_request(log, ctx, err) unless reply

      ctx.res.text(reply[0], status: reply[1])
    end
  end
end
