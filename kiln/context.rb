module Kiln
  class Context
    attr_reader :req, :res, :app, :id, :deadline
    attr_accessor :gone

    def initialize(req, res, app, id, deadline)
      @req = req
      @res = res
      @app = app
      @id = id
      @deadline = deadline
      @gone = false
    end

    def remaining = @deadline - Kiln.now
    def client_gone? = Kiln.client_gone?

    def sleep(sec)
      left = remaining
      raise DeadlineExceeded, 'deadline exceeded' if left <= 0

      if left < sec
        Kiln.pause(left)
        raise DeadlineExceeded, 'deadline exceeded'
      end
      Kiln.pause(sec)
    end

    def all(tasks)
      tasks = Array(tasks)
      raise DeadlineExceeded, 'deadline exceeded' if remaining <= 0
      return [] if tasks.empty?

      box = Queue.new
      threads = []
      count = tasks.size
      begin
        start_tasks(tasks, box, threads)
        results = Array.new(count)
        got = 0
        while got < count
          kind, idx, val = next_result(box)
          raise val if kind == :err

          results[idx] = val
          got += 1
        end
        results
      ensure
        stop(threads)
      end
    end

    def first(tasks)
      tasks = Array(tasks)
      raise ArgumentError, 'no tasks' if tasks.empty?
      raise DeadlineExceeded, 'deadline exceeded' if remaining <= 0

      box = Queue.new
      threads = []
      begin
        start_tasks(tasks, box, threads)
        seen = 0
        last = nil
        while seen < threads.size
          kind, _idx, val = next_result(box)
          return val if kind == :ok

          seen += 1
          last = val
        end
        raise last
      ensure
        stop(threads)
      end
    end

    private

    def start_tasks(tasks, box, threads)
      index = 0
      while index < tasks.size
        threads << spawn(box, index, tasks[index])
        index += 1
      end
    end

    def spawn(box, idx, task)
      deadline_at = @deadline
      request_id = @id
      fd = Thread.current[:kiln_fd]
      Thread.new do
        current = Thread.current
        current.report_on_exception = false
        current[:kiln_deadline] = deadline_at
        current[:request_id] = request_id
        current[:kiln_fd] = fd
        box << [:ok, idx, task.call]
      rescue Exception => err
        raise if Kiln.unwind?(err)

        box << [:err, idx, err]
      end
    end

    def next_result(box)
      left = remaining
      raise DeadlineExceeded, 'deadline exceeded' if left <= 0

      msg = box.pop(timeout: left)
      raise DeadlineExceeded, 'deadline exceeded' if msg.nil?

      msg
    end

    def stop(threads)
      threads.each { |th| th.kill if th.alive? }
      limit = Kiln.now + 0.5
      threads.each do |th|
        left = limit - Kiln.now
        safe_join { th.join(left.positive? ? left : 0) }
      end
    end

    def safe_join
      yield
    rescue Exception
      nil
    end
  end
end
