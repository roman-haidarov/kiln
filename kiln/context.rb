module Kiln
  class Context
    attr_reader :req, :res, :app, :id, :deadline
    attr_accessor :gone

    def text(body, status: nil) = @res.text(body, status: status || @res.status)
    def json(body, status: nil) = @res.json(body, status: status || @res.status)
    def header(name, value) = @res.headers[name] = value
    def status(value) = @res.status = value

    def initialize(req, res, app, id, deadline)
      @req, @res, @app, @id, @deadline = req, res, app, id, deadline
      @gone = false
    end

    def remaining = @deadline - Kiln.now
    def client_gone? = Kiln.client_gone?
    def sleep(sec)
      left = remaining
      raise DeadlineExceeded, "deadline exceeded" if left <= 0
      if left < sec
        Kiln.pause(left)
        raise DeadlineExceeded, "deadline exceeded"
      end
      Kiln.pause(sec)
    end

    def all(tasks)
      tasks = Array(tasks)
      raise DeadlineExceeded, "deadline exceeded" if remaining <= 0
      return [] if tasks.empty?
      box = Queue.new
      threads = []
      begin
        tasks.each_with_index { |task, i| threads << spawn(box, i, task) }
        results = Array.new(tasks.size)
        got = 0
        while got < tasks.size
          kind, idx, val = take(box)
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
      raise ArgumentError, "no tasks" if tasks.empty?
      raise DeadlineExceeded, "deadline exceeded" if remaining <= 0
      box = Queue.new
      threads = []
      begin
        tasks.each_with_index { |task, i| threads << spawn(box, i, task) }
        seen = 0
        last = nil
        while seen < threads.size
          kind, _idx, val = take(box)
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

    def spawn(box, idx, task)
      dl = @deadline
      rid = @id
      fd = Thread.current[:kiln_fd]
      Thread.new do
        Thread.current.report_on_exception = false
        Thread.current[:kiln_deadline] = dl
        Thread.current[:request_id] = rid
        Thread.current[:kiln_fd] = fd
        box << [:ok, idx, task.call]
      rescue Exception => e
        raise if Kiln.unwind?(e)
        box << [:err, idx, e]
      end
    end

    def take(box)
      left = remaining
      raise DeadlineExceeded, "deadline exceeded" if left <= 0
      msg = box.pop(timeout: left)
      raise DeadlineExceeded, "deadline exceeded" if msg.nil?
      msg
    end

    def stop(threads)
      threads.each { |th| th.kill if th.alive? }
      limit = Kiln.now + 0.5
      threads.each do |th|
        left = limit - Kiln.now
        safe_join { th.join(left > 0 ? left : 0) }
      end
    end

    def safe_join
      yield
    rescue Exception
      nil
    end
  end
end
