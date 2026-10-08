module Kiln
  class Log
    CAP = 1024

    def initialize(io = STDOUT)
      @q = SizedQueue.new(CAP)
      @dropped = 0
      @lock = Mutex.new
      @writer = Thread.new do
        Thread.current.report_on_exception = false
        loop do
          begin
            line = @q.pop
          rescue ClosedQueueError
            break
          end
          break if line.nil?
          begin
            io.puts(line)
          rescue Exception
            next
          end
        end
      end
    end

    def info(msg) = push("INFO ", msg)
    def error(msg) = push("ERROR", msg)

    def dropped = @lock.synchronize { @dropped }

    def close
      @q.close unless @q.closed?
      @writer.join
    end

    private

    def push(level, msg)
      @q.push("#{level} #{rid}#{one_line(msg)}", true)
    rescue ThreadError
      @lock.synchronize { @dropped += 1 }
      nil
    rescue ClosedQueueError
      nil
    end

    def one_line(msg)
      msg.to_s.gsub(/[\r\n]+/, " ").gsub(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/, "")
    end

    def rid
      id = Thread.current[:request_id]
      id ? "[#{id}] " : ""
    end
  end
end
