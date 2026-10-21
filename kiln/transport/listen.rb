module Kiln
  module Transport
    class Listen
      KINDS = %i[tcp unix fd].freeze

      attr_reader :kind, :host, :port, :path, :fd, :tls, :mode

      def initialize(kind, tls = nil)
        raise ArgumentError, 'listen kind must be :tcp, :unix or :fd' unless KINDS.include?(kind)
        raise ArgumentError, 'tls must be a Transport::Tls' unless tls.nil? || tls.is_a?(Tls)

        @kind = kind
        @tls = tls
        @host = ''
        @port = 0
        @path = ''
        @fd = -1
        @mode = -1
      end

      def use_tcp(host, port)
        raise ArgumentError, 'port must be 0..65535' unless port.is_a?(Integer) && port.between?(0, 65_535)

        @host = host
        @port = port
        self
      end

      def use_unix(path, mode)
        raise ArgumentError, 'unix path must not be empty' if path.empty?

        @path = path
        @mode = mode
        self
      end

      def use_fd(number)
        raise ArgumentError, 'fd must be a non-negative Integer' unless number.is_a?(Integer) && number >= 0

        @fd = number
        self
      end

      def open(backlog, reuse_port)
        opened = case @kind
                 in :tcp then Sock.kiln_sock_tcp(@host, @port, backlog, reuse_port ? 1 : 0)
                 in :unix then Sock.kiln_sock_unix(@path, backlog, @mode)
                 in :fd then Sock.kiln_sock_kind(@fd).negative? ? Sock.kiln_sock_kind(@fd) : @fd
                 end
        raise Sock.failure("cannot listen on #{self}", opened) if opened.negative?

        opened
      end

      def owns_path? = @kind == :unix
      def tls? = !@tls.nil?

      def to_s
        case @kind
        in :tcp then "#{@host.include?(':') ? "[#{@host}]" : @host}:#{@port}"
        in :unix then "unix:#{@path}"
        in :fd then "fd:#{@fd}"
        end
      end

      class << self
        def tcp(host, port, tls: nil) = Listen.new(:tcp, tls).use_tcp(host, port)
        def unix(path, tls: nil, mode: -1) = Listen.new(:unix, tls).use_unix(path, mode)
        def fd(number, tls: nil) = Listen.new(:fd, tls).use_fd(number)

        def systemd(tls: nil) = Sock.inherited_fds.map { |number| Listen.fd(number, tls: tls) }

        def parse(text, tls: nil)
          return unix(rest_of(text, 5), tls: tls) if text.start_with?('unix:')
          return fd(Integer(rest_of(text, 3)), tls: tls) if text.start_with?('fd:')

          parse_tcp(text, tls)
        end

        def resolve(listen, host, port, tls)
          return [Listen.tcp(host, port, tls: tls)] if listen.nil?

          specs = Array(listen).map { |item| item.is_a?(Listen) ? item : Listen.parse(item.to_s, tls: tls) }
          raise ArgumentError, 'listen must name at least one address' if specs.empty?

          specs
        end

        private

        def parse_tcp(text, tls)
          colon = text.rindex(':')
          raise ArgumentError, "listen address needs host:port: #{text}" if colon.nil?

          tcp(unbracket(text.byteslice(0, colon)), Integer(rest_of(text, colon + 1)), tls: tls)
        end

        def rest_of(text, start) = text.byteslice(start, text.bytesize - start)

        def unbracket(host)
          return host unless host.start_with?('[') && host.end_with?(']')

          host.byteslice(1, host.bytesize - 2)
        end
      end
    end
  end
end
