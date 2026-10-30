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
        @owned_paths = []
        @port = @config.port
        @ports = []
        @started = false
      end

      def start
        raise IOError, 'event server is already running' if @started

        complete = false
        gate = Queue.new
        ready = Queue.new
        begin
          open_listeners
          @children = Array.new(@count) { |index| Event.new(@handler, **lane_options(index)).sequence(index, @count) }
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
          shutdown(grace: 0) unless complete
        end
      end

      def shutdown(grace: 5.0)
        check_rules([['shutdown grace', grace, :seconds_at_least]])
        @children.each(&:drain)
        finished = Queue.new
        threads = [Thread.current].drop(1)
        @children.each do |child|
          threads << Thread.new { finished << child.shutdown(grace: grace) }
        end
        threads.each(&:join)
        left = 0
        @children.size.times { left += finished.pop.to_i }
        left
      ensure
        release_listeners
        @started = false
      end

      def connections = @children.sum(&:connections)
      def in_flight = @children.sum(&:in_flight)
      def killed = @children.sum(&:killed)
      def late = @children.sum(&:late)
      def free_slots = @config.max_conns - connections
      def handling = @children.sum(&:handling)
      def handshakes = @children.sum(&:handshakes)
      def loops = @count

      private

      def lane_count
        count = [Runtime.workers, @config.max_conns, @config.max_streams].min
        count = [count, @config.handlers].min if @config.handlers.positive?
        count = [count, @config.max_connection_rate].min if @config.max_connection_rate.positive?
        count
      end

      def split(total, index)
        (total / @count) + (index < total % @count ? 1 : 0)
      end

      def lane_options(index)
        listeners = @listeners.map do |fd, spec|
          Transport::Listen.fd(fd, tls: spec.tls)
        end
        @options.merge(listen: listeners, reuse_port: false,
                       handlers: split(@config.handlers, index),
                       max_conns: split(@config.max_conns, index),
                       max_streams: split(@config.max_streams, index),
                       max_connection_rate: split(@config.max_connection_rate, index))
      end

      def open_listeners
        Transport::Sock.kiln_sock_ignore_sigpipe
        @listen.each do |spec|
          fd = spec.open(@config.backlog, @config.reuse_port?)
          @listeners << [fd, spec]
          @owned_paths << Transport::Sock.own_path(spec.path) if spec.owns_path?
        end
      end

      def release_listeners
        @listeners.each do |fd, _spec|
          Transport::Sock.kiln_sock_close(fd)
        end
        @listeners.clear
        @owned_paths.each { |record| Transport::Sock.unlink_owned(record) }
        @owned_paths.clear
      end
    end

    private_constant :EventGroup
  end
end
