module Kiln
  module Sock
    ffi_func :kiln_sock_tcp, %i[str long long long], :long
    ffi_func :kiln_sock_unix, %i[str long long], :long
    ffi_func :kiln_sock_kind, [:long], :long
    ffi_func :kiln_sock_port, [:long], :long
    ffi_func :kiln_sock_accept, %i[long long], :long
    ffi_func :kiln_sock_shutdown, %i[long long], :long
    ffi_func :kiln_sock_close, [:long], :long
    ffi_func :kiln_sock_unlink, [:str], :long
    ffi_func :kiln_sock_path_id, %i[str int_array], :long
    ffi_func :kiln_sock_unlink_owned, %i[str long long], :long
    ffi_func :kiln_sock_inherited, [], :long
    ffi_func :kiln_sock_ignore_sigpipe, [], :long
    ffi_func :kiln_sock_errno_text, [:long], :binstr
    ffi_func :kiln_tls_available, [], :long
    ffi_func :kiln_tls_error_text, [], :binstr
    ffi_func :kiln_tls_context_new, %i[str str str long str str long str], :long
    ffi_func :kiln_tls_context_free, [:long], :long

    FIRST_FD = 3
    EAGAIN = -11

    class << self
      def failure(what, code) = IOError.new("#{what}: #{Sock.kiln_sock_errno_text(code)} (#{code})")

      def inherited_fds
        count = Sock.kiln_sock_inherited
        Array.new(count) { |index| FIRST_FD + index }
      end

      def eagain?(code) = code == EAGAIN || code == -35

      def own_path(path)
        identity = [0, 0]
        rc = Sock.kiln_sock_path_id(path, identity)
        raise failure("cannot identify unix socket #{path}", rc) if rc.negative?

        [path, identity[0], identity[1]]
      end

      def unlink_owned(path_record)
        Sock.kiln_sock_unlink_owned(path_record[0], path_record[1], path_record[2])
      end

    end
  end

  class Tls
    VERSIONS = { '1.2' => 0x0303, '1.3' => 0x0304 }.freeze
    VERIFY = { none: 0, optional: 1, require: 2 }.freeze
    DEFAULT_ALPN = ['http/1.1'.freeze].freeze

    attr_reader :cert, :key, :ca, :verify, :ciphers, :ciphersuites, :min_version, :alpn

    def initialize(cert:, key:, ca: nil, verify: :none, ciphers: '', ciphersuites: '', min_version: '1.2',
                   alpn: DEFAULT_ALPN)
      raise ArgumentError, 'tls cert must be a path' unless cert.is_a?(String) && !cert.empty?
      raise ArgumentError, 'tls key must be a path' unless key.is_a?(String) && !key.empty?
      raise ArgumentError, 'tls verify must be :none, :optional or :require' unless VERIFY.key?(verify)
      raise ArgumentError, 'tls min_version must be "1.2" or "1.3"' unless VERSIONS.key?(min_version)
      raise ArgumentError, 'tls verify needs ca:' if verify != :none && ca.nil?
      raise ArgumentError, 'tls supports only the http/1.1 ALPN protocol' unless alpn_list?(alpn)

      @cert = cert
      @key = key
      @ca = ca
      @verify = verify
      @ciphers = ciphers
      @ciphersuites = ciphersuites
      @min_version = min_version
      @alpn = DEFAULT_ALPN
      @context = -1
    end

    def context
      return @context if @context >= 0

      raise IOError, "TLS unavailable: #{Sock.kiln_tls_error_text}" if Sock.kiln_tls_available.zero?

      made = Sock.kiln_tls_context_new(@cert, @key, @ca || '', VERIFY[@verify], @ciphers, @ciphersuites,
                                       VERSIONS[@min_version], @alpn.join(','))
      raise IOError, "TLS setup failed: #{Sock.kiln_tls_error_text}" if made.negative?

      @context = made
    end

    def release
      return if @context.negative?

      Sock.kiln_tls_context_free(@context)
      @context = -1
    end

    class << self
      def available? = Sock.kiln_tls_available == 1
    end

    private

    def alpn_list?(list)
      return false unless list.is_a?(Array)

      list.size == 1 && list[0].is_a?(String) && list[0] == 'http/1.1'
    end
  end

  class Listen
    KINDS = %i[tcp unix fd].freeze

    attr_reader :kind, :host, :port, :path, :fd, :tls, :mode

    def initialize(kind, host: '', port: 0, path: '', fd: -1, tls: nil, mode: -1)
      raise ArgumentError, 'listen kind must be :tcp, :unix or :fd' unless KINDS.include?(kind)
      raise ArgumentError, 'port must be 0..65535' unless port.is_a?(Integer) && port.between?(0, 65_535)
      raise ArgumentError, 'tls must be a Kiln::Tls' unless tls.nil? || tls.is_a?(Tls)
      raise ArgumentError, 'fd must be a non-negative Integer' if kind == :fd && !(fd.is_a?(Integer) && fd >= 0)
      raise ArgumentError, 'unix path must not be empty' if kind == :unix && path.empty?

      @kind = kind
      @host = host
      @port = port
      @path = path
      @fd = fd
      @tls = tls
      @mode = mode
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
      def tcp(host, port, tls: nil) = Listen.new(:tcp, host: host, port: port, tls: tls)
      def unix(path, tls: nil, mode: -1) = Listen.new(:unix, path: path, tls: tls, mode: mode)
      def fd(number, tls: nil) = Listen.new(:fd, fd: number, tls: tls)

      def systemd(tls: nil) = Sock.inherited_fds.map { |number| Listen.fd(number, tls: tls) }

      def parse(text, tls: nil)
        return unix(text.byteslice(5, text.bytesize - 5), tls: tls) if text.start_with?('unix:')
        return fd(Integer(text.byteslice(3, text.bytesize - 3)), tls: tls) if text.start_with?('fd:')

        colon = text.rindex(':')
        raise ArgumentError, "listen address needs host:port: #{text}" if colon.nil?

        host = text.byteslice(0, colon)
        host = host.byteslice(1, host.bytesize - 2) if host.start_with?('[') && host.end_with?(']')
        tcp(host, Integer(text.byteslice(colon + 1, text.bytesize - colon - 1)), tls: tls)
      end

      def resolve(listen, host, port, tls)
        return [Listen.tcp(host, port, tls: tls)] if listen.nil?

        specs = Array(listen).map { |item| item.is_a?(Listen) ? item : Listen.parse(item.to_s, tls: tls) }
        raise ArgumentError, 'listen must name at least one address' if specs.empty?

        specs
      end
    end
  end
end
