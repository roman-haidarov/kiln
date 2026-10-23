module Kiln
  module Runtime
    class DeadlineExceeded < StandardError; end
    class PoolTimeout < StandardError; end
    class WorkerLost < StandardError; end
    class ClientGone < StandardError; end

    FAILURES = [StandardError, ScriptError, SecurityError, NoMemoryError, SystemStackError].freeze
    STOPS = [SystemExit, SignalException].freeze
    ERRORS = (FAILURES + STOPS).freeze
  end
end
