module Kiln
  module Routing
    class Context
      module Tasks
        def all(tasks)
          tasks = Array(tasks)
          check_deadline
          return [] if tasks.empty?

          threads = []
          begin
            gather_all(start_tasks(tasks, threads), tasks.size)
          ensure
            stop(threads)
          end
        end

        def first(tasks)
          tasks = Array(tasks)
          raise ArgumentError, 'no tasks' if tasks.empty?

          check_deadline
          threads = []
          begin
            box = start_tasks(tasks, threads)
            first_success(box, threads.size)
          ensure
            stop(threads)
          end
        end

        private

        def check_deadline
          raise Runtime::DeadlineExceeded, 'deadline exceeded' if remaining <= 0
        end

        def gather_all(box, count)
          results = Array.new(count)
          got = 0
          while got < count
            kind, idx, val = next_result(box)
            raise val if kind == :err

            results[idx] = val
            got += 1
          end
          results
        end

        def first_success(box, count)
          seen = 0
          last = nil
          while seen < count
            kind, _idx, val = next_result(box)
            return val if kind == :ok

            seen += 1
            last = val
          end
          raise last
        end

        def start_tasks(tasks, threads)
          box = Queue.new
          index = 0
          while index < tasks.size
            threads << spawn(box, index, tasks[index])
            index += 1
          end
          box
        end

        def spawn(box, idx, task)
          deadline_at = @deadline
          request_id = @id
          fd = Thread.current[:kiln_fd]
          Thread.new do
            adopt(deadline_at, request_id, fd)
            box << [:ok, idx, task.call]
          rescue *Kiln::Runtime::FAILURES => e
            box << [:err, idx, e]
          end
        end

        def adopt(deadline_at, request_id, socket_fd)
          current = Thread.current
          current.report_on_exception = false
          current[:kiln_deadline] = deadline_at
          current[:request_id] = request_id
          current[:kiln_fd] = socket_fd
        end

        def next_result(box)
          left = remaining
          raise Runtime::DeadlineExceeded, 'deadline exceeded' if left <= 0

          msg = box.pop(timeout: left)
          raise Runtime::DeadlineExceeded, 'deadline exceeded' if msg.nil?

          msg
        end

        def stop(threads)
          threads.each { |th| th.kill if th.alive? }
          limit = Kiln::Runtime.now + 0.5
          threads.each do |th|
            left = limit - Kiln::Runtime.now
            safe_join { th.join(left.positive? ? left : 0) }
          end
        end

        def safe_join
          yield
        rescue *Kiln::Runtime::FAILURES
          nil
        end
      end

      include Tasks

      attr_reader :req, :res, :id, :deadline
      attr_accessor :gone, :prepared

      def initialize(req, res, id, deadline)
        @req = req
        @res = res
        @id = id
        @deadline = deadline
        @gone = false
        @prepared = false
      end

      def remaining = @deadline - Kiln::Runtime.now
      def client_gone? = Kiln::Runtime.client_gone?

      def sleep(sec)
        left = remaining
        raise Runtime::DeadlineExceeded, 'deadline exceeded' if left <= 0

        if left < sec
          Kiln::Runtime.pause(left)
          raise Runtime::DeadlineExceeded, 'deadline exceeded'
        end
        Kiln::Runtime.pause(sec)
      end
    end
  end
end
