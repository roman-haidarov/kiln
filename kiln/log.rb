module Kiln
  # Один тред-писатель: строки не перемешиваются, хендлеры не ждут stdout.
  class Log
    def initialize(io = STDOUT)
      @q = Queue.new
      @writer = Thread.new { while (line = @q.pop) do io.puts(line) end }
    end

    def info(msg)  = @q << "INFO  #{rid}#{msg}"
    def error(msg) = @q << "ERROR #{rid}#{msg}"

    def close
      @q.close
      @writer.join
    end

    private

    def rid
      id = Thread.current[:request_id]
      id ? "[#{id}] " : ""
    end
  end
end
