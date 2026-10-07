module Kiln
  class DeadlineExceeded < StandardError; end
  class PoolTimeout < StandardError; end

  def self.now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
