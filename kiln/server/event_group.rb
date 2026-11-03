module Kiln
  class Server
    class EventGroup
      include Runtime::Check

      attr_reader :port, :ports

      def initialize(handler, **options)
        @handler = handler
        @options = options
        @config = Settings.event(options)
        @listen = @config.listen
        @count = lane_count
        @children = []
        @listeners = []
        @lent = []
        @tls_owned = []
        @owned_paths = []
        @group = 0
        @port = @config.port
        @ports = []
        @started = false
        @stop_lock = Mutex.new
      end

      def start
        raise IOError, 'event server is already running' if @started

        complete = false
        gate = Queue.new
        ready = Queue.new
        begin
          open_listeners
          open_group
          @children = Array.new(@count) do |index|
            Event.new(@handler, **lane_options(index)).sequence(index, @count).share(@group, 1)
          end
          @children.each { |child| child.start(defer_handlers: true, gate: gate, ready: ready) }
          @count.times do
            raise IOError, 'event worker did not start' unless ready.pop(timeout: 5.0)
          end
          @children.each(&:activate_handlers)
          @ports = @children.first.ports
          @port = Kiln::Runtime.first_port(@ports)
          @started = true
          complete = true
          self
        ensure
          gate.close
          @stop_lock.synchronize { stop_children(0) } unless complete
        end
      end

      def shutdown(grace: 5.0)
        check_rules([['shutdown grace', grace, :seconds_at_least]])
        @stop_lock.synchronize { stop_children(grace) }
      end

      def connections = @children.sum(&:connections)
      def admitted
        @children.each do |child|
          count = child.admission_count
          return count unless count.nil?
        end
        0
      end
      def in_flight = @children.sum(&:in_flight)
      def killed = @children.sum(&:killed)
      def late = @children.sum(&:late)
      def free_slots = [@config.max_conns - admitted, 0].max
      def handling = @children.sum(&:handling)
      def handshakes = @children.sum(&:handshakes)
      def loops = @count
      def loop_stats = @children.map(&:stats)
      def queued_requests
        @children.each do |child|
          count = child.pending_requests_count
          return count unless count.nil?
        end
        0
      end

      def queued_bytes
        @children.each do |child|
          count = child.pending_bytes_count
          return count unless count.nil?
        end
        0
      end

      private

      def stop_children(grace)
        return 0 if @children.empty? && @listeners.empty? && @group.zero?

        stop_started(grace)
      ensure
        release_listeners
        @children = []
        @started = false
      end

      def stop_started(grace)
        @children.each(&:drain)
        close_listener_fds
        finished = Queue.new
        threads = [Thread.current].drop(1)
        @children.each do |child|
          threads << Thread.new { finished << child.shutdown(grace: grace) }
        end
        threads.each(&:join)
        left = 0
        @children.size.times { left += finished.pop.to_i }
        left
      end

      def lane_count
        count = Runtime.workers
        count = [count, @config.handlers].min if @config.handlers.positive?
        count = [count, @config.max_connection_rate].min if @config.max_connection_rate.positive?
        count
      end

      def split(total, index)
        (total / @count) + (index < total % @count ? 1 : 0)
      end

      def lane_options(index)
        listeners = Array.new(@listeners.size) do |at|
          Transport::Listen.fd(@listeners[at], tls: @lent[at])
        end
        @options.merge(listen: listeners, reuse_port: false,
                       handlers: split(@config.handlers, index),
                       max_connection_rate: split(@config.max_connection_rate, index))
      end

      def open_listeners
        Transport::Sock.kiln_sock_ignore_sigpipe
        @listen.each do |spec|
          fd = spec.open(@config.backlog, @config.reuse_port?)
          @listeners << fd
          @lent << lend_tls(spec.tls)
          @owned_paths << Transport::Sock.own_path(spec.path) if spec.owns_path?
        end
      end

      def lend_tls(tls)
        return nil if tls.nil?

        owned = tls.copy
        @tls_owned << owned
        owned.lend
      end

      def open_group
        @group = Uv.kiln_uv_group_new
        raise NoMemoryError, 'cannot allocate event loop group' if @group.zero?
      end

      def close_listener_fds
        @listeners.each { |fd| Transport::Sock.kiln_sock_close(fd) }
        @listeners.clear
      end

      def release_listeners
        close_listener_fds
        @lent.clear
        @tls_owned.each(&:release)
        @tls_owned.clear
        Uv.kiln_uv_group_release(@group) if @group.positive?
        @group = 0
        @owned_paths.each { |record| Transport::Sock.unlink_owned(record) }
        @owned_paths.clear
      end
    end

    private_constant :EventGroup
  end
end
