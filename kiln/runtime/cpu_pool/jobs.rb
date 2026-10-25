module Kiln
  module Runtime
    module CpuPoolJobs
      Job = Struct.new(:work, :reply, :expires, :deadline, :request_id, :by_deadline)

      private

      def new_job(work, timeout)
        started = Kiln::Runtime.now
        expires = started + timeout
        deadline = Kiln::Runtime.deadline
        by_deadline = deadline.positive? && deadline <= expires
        expires = deadline if by_deadline
        raise DeadlineExceeded, 'deadline exceeded' if by_deadline && expires <= started

        Job.new(work, Queue.new, expires, deadline, Thread.current[:request_id], by_deadline)
      end

      def raise_unsent(job)
        raise DeadlineExceeded, 'deadline exceeded' if job.by_deadline

        raise PoolTimeout, closed? ? 'cpu pool closed' : 'cpu pool timeout'
      end

      def submit_and_wait(job)
        return unless enqueue?(job)

        rest = job.expires - Kiln::Runtime.now
        job.reply.pop(timeout: rest) if rest.positive?
      end

      def enqueue?(job)
        return true if push_now?(job)
        return false if closed?

        push_until?(job)
      end

      def push_now?(job)
        @jobs.push(job, true)
        true
      rescue ThreadError, ClosedQueueError
        false
      end

      def push_until?(job)
        rest = job.expires - Kiln::Runtime.now
        rest.positive? && @jobs.push(job, timeout: rest) && Kiln::Runtime.now < job.expires
      rescue ClosedQueueError
        false
      end

      def run_job(job)
        current = Thread.current
        current[:kiln_cpu_reply] = job.reply
        return skip_job(job, current) unless start_job?(job, current)

        msg, fatal = perform(job, current)
        finish_job(job, current)
        job.reply << msg
        current[:kiln_cpu_reply] = nil
        raise fatal if fatal

        nil
      end

      def start_job?(job, current)
        @lock.synchronize do
          if Kiln::Runtime.now >= job.expires
            @skipped += 1
            false
          else
            @busy += 1
            current[:kiln_cpu_busy] = true
            true
          end
        end
      end

      def skip_job(job, current)
        error = job.by_deadline ? DeadlineExceeded.new('deadline exceeded') : PoolTimeout.new('cpu pool timeout')
        job.reply << [:err, error]
        current[:kiln_cpu_reply] = nil
        nil
      end

      def perform(job, current)
        current[:kiln_deadline] = job.deadline
        current[:request_id] = job.request_id
        [[:ok, job.work.call], nil]
      rescue *Kiln::Runtime::FAILURES => e
        [[:err, e], nil]
      rescue *Kiln::Runtime::STOPS => e
        [[:err, WorkerLost.new("cpu worker terminated by #{e.class}")], e]
      end

      def finish_job(job, current)
        finished = Kiln::Runtime.now
        @lock.synchronize do
          @busy -= 1
          current[:kiln_cpu_busy] = false
          note_overrun(finished - job.expires) if finished > job.expires
        end
        current[:kiln_deadline] = nil
        current[:request_id] = nil
      end

      def note_overrun(seconds)
        @overran += 1
        @overran_seconds += seconds
      end

      def fail_queued
        until @jobs.empty?
          job = @jobs.pop
          job.reply << [:err, WorkerLost.new('cpu pool shutdown')] if job
        end
      end
    end

  end
end
