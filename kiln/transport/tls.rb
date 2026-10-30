module Kiln
  module Transport
    class Tls
      VERSIONS = { '1.2' => 0x0303, '1.3' => 0x0304 }.freeze
      VERIFY = { none: 0, optional: 1, require: 2 }.freeze
      DEFAULT_ALPN = ['http/1.1'.freeze].freeze

      attr_reader :cert, :key, :ca, :verify, :ciphers, :ciphersuites, :min_version, :alpn

      OPTION_KEYS = %i[ca verify ciphers ciphersuites min_version alpn].freeze

      def initialize(cert:, key:, **options)
        init_paths(cert, key)
        init_options(options)
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

      def copy
        Tls.new(cert: @cert, key: @key, ca: @ca, verify: @verify, ciphers: @ciphers,
                ciphersuites: @ciphersuites, min_version: @min_version, alpn: @alpn)
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

      def init_paths(cert, key)
        raise ArgumentError, 'tls cert must be a path' unless path?(cert)
        raise ArgumentError, 'tls key must be a path' unless path?(key)

        @cert = cert
        @key = key
      end

      def init_options(options)
        unknown = options.keys - OPTION_KEYS
        raise ArgumentError, "unknown tls option #{unknown.first}" unless unknown.empty?

        @ca = options[:ca]
        @verify = options.fetch(:verify, :none)
        @ciphers = options.fetch(:ciphers) { '' }
        @ciphersuites = options.fetch(:ciphersuites) { '' }
        @min_version = options.fetch(:min_version) { '1.2' }
        check_settings(options.fetch(:alpn) { DEFAULT_ALPN })
      end

      def check_settings(alpn)
        raise ArgumentError, 'tls verify must be :none, :optional or :require' unless VERIFY.key?(@verify)
        raise ArgumentError, 'tls min_version must be "1.2" or "1.3"' unless VERSIONS.key?(@min_version)
        raise ArgumentError, 'tls verify needs ca:' if @verify != :none && @ca.nil?
        raise ArgumentError, 'tls supports only the http/1.1 ALPN protocol' unless alpn_list?(alpn)
      end

      def path?(value) = value.is_a?(String) && !value.empty?

      def alpn_list?(list)
        return false unless list.is_a?(Array)

        list.size == 1 && list[0].is_a?(String) && list[0] == 'http/1.1'
      end
    end
  end
end
