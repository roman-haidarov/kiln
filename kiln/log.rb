module Kiln
  class << self
    def report_error(log, err)
      return unless log

      frames = Array(err.backtrace).first(12).join(' ')
      log.error("#{err.class}: #{err.message} #{frames}")
    rescue Exception
      nil
    end

    def fail_request(log, ctx, err)
      raise err if unwind?(err)

      report_error(log, err)
      ctx.res.text("internal error\n", status: 500)
    end

    def request_text(id)
      id.is_a?(Integer) ? id.to_s : id
    end
  end

  class Log
    CAP = 1024

    def initialize(io = $stdout)
      @queue = SizedQueue.new(CAP)
      @dropped = 0
      @lock = Mutex.new
      @writer = Thread.new do
        Thread.current.report_on_exception = false
        loop do
          begin
            line = @queue.pop
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

    def info(msg) = push('INFO ', msg)
    def error(msg) = push('ERROR', msg)

    def dropped = @lock.synchronize { @dropped }

    def close
      @queue.close unless @queue.closed?
      @writer.join
    end

    private

    def push(level, msg)
      @queue.push("#{level} #{rid}#{one_line(msg)}", true)
    rescue ThreadError
      @lock.synchronize { @dropped += 1 }
      nil
    rescue ClosedQueueError
      nil
    end

    def one_line(msg)
      msg.to_s.gsub(/[\r\n]+/, ' ').gsub(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/, '')
    end

    def rid
      id = Thread.current[:request_id]
      return '' unless id

      "[#{Kiln.request_text(id)}] "
    end
  end
end
