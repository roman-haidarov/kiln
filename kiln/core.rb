module Kiln
  class DeadlineExceeded < StandardError; end
  class PoolTimeout < StandardError; end
  class WorkerLost < StandardError; end
  class ClientGone < StandardError; end

  class << self
    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def deadline
      d = Thread.current[:kiln_deadline]
      d.nil? ? 0.0 : d
    end

    def remaining
      d = deadline
      d > 0 ? d - now : nil
    end

    def check!
      left = remaining
      raise DeadlineExceeded, "deadline exceeded" if left && left <= 0
    end

    def pause(sec)
      left = remaining
      if left && left < sec
        Kernel.sleep(left) if left > 0
        raise DeadlineExceeded, "deadline exceeded"
      end
      Kernel.sleep(sec)
    end

    def client_gone?
      fd = Thread.current[:kiln_fd]
      return false if fd.nil?
      HttpNative.kiln_peer_closed(fd) == 1
    end

    def check_client!
      raise ClientGone, "client disconnected" if client_gone?
    end

    def unwind?(error)
      error.is_a?(SystemExit) || error.is_a?(SignalException)
    end
  end
end
