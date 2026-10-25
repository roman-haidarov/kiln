module Kiln
  class Server
    class Event
      module Workers
        private

        def living(threads)
          kept = [Thread.current].drop(1)
          threads.each { |thread| kept << thread if thread.alive? }
          kept
        end

        def workers_stopped?
          @workers.all? { |thread| !thread.alive? } && @retired.all? { |thread| !thread.alive? }
        end

        def start_worker(index)
          Thread.new do
            Thread.current.report_on_exception = false
            work(@jobs, index)
          end
        end

        def expire_handlers
          now = Kiln::Runtime.now
          expired = 0
          index = 0
          while index < @handlers
            job = take_expired(index, now)
            expired += expire_job(index, job) if job
            index += 1
          end
          expired
        end

        def take_expired(index, now)
          @active_locks[index].synchronize do
            current = @active[index]
            if current && current.ctx.deadline <= now
              @active[index] = nil
              current
            end
          end
        end

        def expire_job(index, job)
          replace_worker(index)
          @done << Dispatch.new(timed_out(job.ctx), job.slot, job.gen)
          @killed += 1
          1
        end

        def replace_worker(index)
          @worker_lock.synchronize do
            worker = @workers[index]
            worker.kill if worker.alive?
            @retired = living(@retired)
            @retired << worker
            @workers[index] = start_worker(index) unless @stop
          end
        end

        def expire_uploads
          now = Kiln::Runtime.now
          expired = 0
          @uploads.each_value do |job|
            next unless job.ctx.deadline <= now && job.claim!

            expire_upload(job)
            expired += 1
          end
          expired
        end

        def expire_upload(job)
          job.thread&.kill
          @uploads.delete(job.slot)
          @done << Dispatch.new(timed_out(job.ctx), job.slot, job.gen)
          @killed += 1
        end

        def timed_out(ctx)
          timed = Routing::Context.new(ctx.req, HTTP::Response.new, ctx.id, ctx.deadline)
          timed.res.text(DEADLINE_BODY, status: 504)
          timed
        end

        def work(lane, index)
          while (job = lane.pop)
            break unless job_finished?(job, index)

            @done << job
            nudge_pump
          end
        end

        def job_finished?(job, index)
          @active_locks[index].synchronize { @active[index] = job }
          run_job(job) unless job.ctx.prepared
          release_active?(job, index)
        end

        def run_job(job)
          ctx = job.ctx
          nudge_pump(ctx.deadline)
          run(ctx) if Kiln::Runtime.now < ctx.deadline
          job.ctx = fallback_context(ctx, 504, DEADLINE_BODY) if Kiln::Runtime.now >= ctx.deadline
        end

        def release_active?(job, index)
          @active_locks[index].synchronize do
            if @active[index].equal?(job)
              @active[index] = nil
              true
            else
              false
            end
          end
        end
      end

    end
  end
end
