module Kiln
  class Server
    class Event
      module Lifecycle
        def start
          raise IOError, 'another Kiln::Server::Event is already running in this process' if Uv.kiln_uv_running == 1

          Transport::Sock.kiln_sock_ignore_sigpipe
          open_listeners
          @poller = IO.for_fd(Uv.kiln_uv_fd, autoclose: false)
          start_lanes
          @pump = Thread.new { pump_thread }
          self
        end

        private

        def start_lanes
          @handlers.times do |index|
            @workers << start_worker(index)
          end
        end

        def pump_thread
          Thread.current.report_on_exception = false
          rc = Uv.kiln_uv_sigpipe_enter
          raise IOError, "cannot block SIGPIPE on event thread (#{rc})" unless rc.zero?

          begin
            pump
          ensure
            Uv.kiln_uv_sigpipe_leave
          end
        end

        def open_listeners
          rc = Uv.kiln_uv_configure(@settings, @settings.size)
          raise IOError, "kiln event server setup failed: #{Uv.kiln_uv_error_text(rc)} (#{rc})" unless rc.zero?

          start_listening
          @ports = Array.new(@listen.size) { |index| Uv.kiln_uv_port(index) }
          @port = Kiln::Runtime.first_port(@ports)
        end

        def start_listening
          started = false
          begin
            @listen.each { |spec| adopt(spec) }
            rc = Uv.kiln_uv_start
            raise IOError, "kiln event server listen failed: #{Uv.kiln_uv_error_text(rc)} (#{rc})" unless rc.zero?

            started = true
          ensure
            abandon_listen unless started
          end
        end

        def abandon_listen
          Uv.kiln_uv_abandon
          release_listeners
        end

        def adopt(spec)
          fd = spec.open(@backlog, @reuse_port)
          @owned_paths << Transport::Sock.own_path(spec.path) if spec.owns_path?
          tls = spec.tls
          context = tls.nil? ? -1 : tls.context
          index = Uv.kiln_uv_adopt(fd, context)
          return unless index.negative?

          Transport::Sock.kiln_sock_close(fd) if spec.kind != :fd
          raise IOError, "kiln event server cannot use #{spec}: #{Uv.kiln_uv_error_text(index)} (#{index})"
        end

        def release_listeners
          @owned_paths.each { |record| Transport::Sock.unlink_owned(record) }
          @owned_paths.clear
          @listen.each { |spec| spec.tls&.release }
        end
      end

      module Stopping
        def shutdown(grace: 5.0)
          check_rules([['shutdown grace', grace, :seconds_at_least]])
          return 0 if @stopped || @pump.nil?

          begin_drain
          await_quiet(Kiln::Runtime.now + grace)
          left = @quiet ? 0 : cut_off
          stop_all(left.zero? ? 0.5 : 0)
          left + @aborted_taken + @aborted_count
        end

        private

        def begin_drain
          @stopped = true
          @quiet = false
          @draining = true
          wake_pump
        end

        def await_quiet(limit)
          Kernel.sleep 0.01 until @quiet || !@pump.alive? || Kiln::Runtime.now >= limit
        end

        def cut_off
          @cutoff = true
          return @inflight unless @handlers.positive?

          wake_pump
          ready_limit = Kiln::Runtime.now + 0.5
          Kernel.sleep 0.001 until @dispatch_ready || !@pump.alive? || Kiln::Runtime.now >= ready_limit
          @inflight
        end

        def stop_all(pause)
          @jobs.close
          @stop = true
          wake_pump
          threads = @worker_lock.synchronize { @workers + @retired }
          stop_threads(threads, Kiln::Runtime.now + pause)
          wake_pump
          stop_pump(Kiln::Runtime.now + pause)
          release_listeners
        end

        def stop_threads(threads, deadline)
          threads.each do |thread|
            wait_dead(thread, deadline)
            thread.kill if thread.alive?
            wait_dead(thread, Kiln::Runtime.now + 1.0)
            next if thread.alive?

            join_or_log(thread)
          end
        end

        def stop_pump(deadline)
          thread = @pump
          wait_dead(thread, deadline)
          if thread.alive?
            @wake_lock.synchronize do
              thread.kill if @inline_busy && !@pump_stopping
            end
          end
          wait_dead(thread, Kiln::Runtime.now + 1.0)
          return if thread.alive?

          join_or_log(thread)
        end

        def wait_dead(thread, deadline)
          Kernel.sleep 0.01 while thread.alive? && Kiln::Runtime.now < deadline
        end

        def join_or_log(thread)
          thread.join
        rescue StandardError => e
          @log&.error("event server thread stopped with #{e.class}: #{e.message}")
        end
      end

    end
  end
end
