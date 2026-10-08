module Kiln
  class Supervisor
    MIN_DELAY = 0.1
    MAX_DELAY = 5.0
    STABLE = 10.0

    def initialize(log)
      @log = log
      @children = []
      @stopping = false
      @restarts = 0
      @lock = Mutex.new
    end

    def child(name, &body)
      @children << Thread.new do
        Thread.current.report_on_exception = false
        delay = MIN_DELAY
        until @stopping
          started = Kiln.now
          begin
            body.call
            break
          rescue Exception => e
            break if @stopping || Kiln.unwind?(e)
            delay = MIN_DELAY if Kiln.now - started > STABLE
            @lock.synchronize { @restarts += 1 }
            safe_log(name, e, delay)
            Kernel.sleep delay unless @stopping
            delay = delay * 2 > MAX_DELAY ? MAX_DELAY : delay * 2
          end
        end
      end
    end

    def restarts = @lock.synchronize { @restarts }

    def stop
      @stopping = true
      @children.each { |t| t.kill if t.alive? }
      @children.each { |t| safe_join { t.join(2) } }
    end

    private

    def safe_join
      yield
    rescue Exception
      nil
    end

    def safe_log(name, error, delay)
      @log.error("service #{name} crashed: #{error.class}: #{error.message}; restart in #{delay}s")
    rescue Exception
      nil
    end
  end
end
