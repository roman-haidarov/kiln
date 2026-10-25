module Kiln
  class Server
    class Event
      module Pumping
        private

        def pump
          scan = Array.new(HTTP::Native::CAP, 0)
          meta = Array.new(META, 0)
          drained = false
          drained = pump_round(scan, meta, drained) until @stop && workers_stopped?
          drain_done
          Uv.kiln_uv_flush
          Uv.kiln_uv_poll
        ensure
          pump_teardown
        end

        def pump_round(scan, meta, drained)
          drained = start_drain(drained)
          Uv.kiln_uv_poll
          handled = pump_events + take_requests(scan, meta)
          @dispatch_ready = true if @cutoff
          Uv.kiln_uv_flush
          @quiet = drained && @inflight.zero? && Uv.kiln_uv_busy.zero?
          idle(drained) if handled.zero?
          drained
        rescue Runtime::DeadlineExceeded
          drained
        end

        def idle(drained)
          park(drained ? 0.01 : handler_wait) if Uv.kiln_uv_settle.zero?
        end

        def start_drain(drained)
          return drained if drained || !@draining

          Uv.kiln_uv_drain
          @inlets.each_value(&:nudge)
          true
        end

        def pump_events
          handled = drain_done + pump_streams + expire_handlers
          handled += promote_stalled unless @stalled.empty?
          handled += pump_inlets unless @inlets.empty?
          handled += expire_uploads unless @uploads.empty?
          handled
        end

        def take_requests(scan, meta)
          handled = 0
          loop do
            src = Uv.kiln_uv_next(scan, HTTP::Native::CAP, meta)
            break if src.empty?

            take_request(src, scan, meta)
            handled += 1
          end
          handled
        end

        def take_request(src, scan, meta)
          return serve(src, scan, meta) unless @cutoff

          Uv.kiln_uv_abort(meta[3], meta[4])
          @aborted_taken += 1
        end

        def pump_teardown
          halt_streams
          stop_workers_now
        ensure
          close_uv
        end

        def halt_streams
          @outlets.each_value(&:halt)
          @inlets.each_value(&:halt)
          @uploads.each_value { |job| job.thread&.kill }
        end

        def stop_workers_now
          @wake_lock.synchronize { @pump_stopping = true }
          @jobs.close
          @workers.each(&:kill)
          @retired.each(&:kill)
          Kernel.sleep 0.01 until workers_stopped?
        end

        def close_uv
          @wake_lock.synchronize { stop_uv unless @uv_closed }
        end

        def stop_uv
          Uv.kiln_uv_stop
          @aborted_count = Uv.kiln_uv_aborted
          @uv_closed = true
        end
      end

      module Waking
        private

        def park(timeout)
          timeout = libuv_bound(timeout)
          @wake_lock.synchronize do
            @parked = true
            @wake_at = Kiln::Runtime.now + timeout
          end
          @poller.wait_readable(timeout) if idle_pump?
        ensure
          @wake_lock.synchronize { @parked = false }
        end

        def libuv_bound(timeout)
          uv_timeout = Uv.kiln_uv_timeout
          libuv_wait = uv_timeout * 0.001
          uv_timeout >= 0 && libuv_wait < timeout ? libuv_wait : timeout
        end

        def idle_pump? = @done.empty? && @ready.empty? && (@inlets.empty? || @wants.empty?)

        def wake_pump
          @wake_lock.synchronize { Uv.kiln_uv_wake if wakeable? }
        end

        def nudge_pump(deadline = nil)
          @wake_lock.synchronize do
            return unless @parked
            return if deadline && deadline >= @wake_at

            Uv.kiln_uv_wake if wakeable?
          end
        end

        def wakeable? = !@uv_closed && !@pump_stopping && @pump&.alive? == true

        def handler_wait
          now = Kiln::Runtime.now
          wait = active_wait(now, HANDLER_WAIT)
          return wait if wait <= 0 || @uploads.empty?

          upload_wait(now, wait)
        end

        def active_wait(now, wait)
          index = 0
          while index < @handlers
            job = @active_locks[index].synchronize { @active[index] }
            wait = [wait, job.ctx.deadline - now].min if job
            return 0 if wait <= 0

            index += 1
          end
          wait
        end

        def upload_wait(now, wait)
          @uploads.each_value do |upload|
            wait = [wait, upload.ctx.deadline - now].min
            return 0 if wait <= 0
          end
          wait
        end
      end

    end
  end
end
