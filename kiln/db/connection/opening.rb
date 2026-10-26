module Kiln
  module DB
    class Conn
      module Opening
        def open(kind, host, port, *auth, **options)
          raise Unsupported, 'Kiln::DB on an inline event-loop handler' if Thread.current[:kiln_inline]

          check_open(auth, options)
          cache = options.fetch(:statement_cache, 32)
          raise ConfigError, 'statement_cache' unless cache_capacity?(cache)

          endpoint = build_endpoint(kind, host, port, auth, options.fetch(:tls, :verify_full))
          timeout = options.fetch(:timeout) { DEFAULT_TIMEOUT }
          raise ConfigError, 'timeout' unless timeout.is_a?(Numeric) && timeout.positive?

          connect(kind, endpoint, timeout, cache)
        end

        def tls_settings(kind, ca_path, tls_name, tls)
          return [Native::SSL_DISABLE, '', ''] if tls == :disable
          raise ConfigError, 'tls must be :verify_full or :disable' unless tls == :verify_full

          ca = ca_file(kind, ca_path)
          raise ConfigError, 'verify-full needs a TLS server name' unless tls_name.is_a?(String) && !tls_name.empty?

          [Native::SSL_VERIFY_FULL, ca, tls_name]
        end

        def sqlstate(packed)
          return nil if [nil, 0].include?(packed)

          text = ''
          i = 0
          while i < 5
            byte = (packed >> (8 * i)) & 0xff
            break if byte.zero?

            text += byte.chr
            i += 1
          end
          text.empty? ? nil : text
        end

        def error_class(code)
          case code
          when Native::DEADLOCK then Deadlock
          when Native::SERIAL then SerializationFailure
          when Native::UNIQUE then UniqueViolation
          when Native::FK then ForeignKeyViolation
          when Native::NOTNULL then NotNullViolation
          when Native::CHECK then CheckViolation
          when Native::LOCKWAIT then LockWaitTimeout
          when Native::CAPACITY then CapacityError
          when Native::UNSUPPORTED then Unsupported
          when Native::CONN then ConnectionError
          when Native::OWNERSHIP, Native::BUSY then OwnershipError
          when Native::CONFIG then ConfigError
          when Native::STALE then StaleView
          else Error
          end
        end

        private

        def check_open(auth, options)
          raise ArgumentError, "wrong number of arguments (given #{auth.size + 3}, expected 8)" unless auth.size == 5

          unknown = options.keys - OPEN_KEYS
          raise ArgumentError, "unknown keyword: :#{unknown.first}" unless unknown.empty?
        end

        def build_endpoint(kind, host, port, auth, tls)
          endpoint = Endpoint.new(host.to_s, port, auth.first(3).map(&:to_s))
          ssl, ca, name = tls_settings(kind, auth[3], auth[4], tls)
          endpoint.secure(ssl, ca, name)
        end

        def ca_file(kind, ca_path)
          if ca_path == :system
            raise ConfigError, 'ca: :system is supported for PostgreSQL only' if kind != Native::KIND_PG

            return 'system'
          end
          raise ConfigError, 'verify-full needs a CA file path' unless ca_path.is_a?(String) && !ca_path.empty?

          ca_path
        end

        def connect(kind, endpoint, timeout, cache)
          prepare_native(kind)
          conn = new(kind, create_handle(kind, endpoint), endpoint.database)
          conn.timeout = timeout
          conn.establish(endpoint.host, cache)
          conn
        end

        def cache_capacity?(value) = value.is_a?(Integer) && value >= 0 && value <= 256

        def prepare_native(kind)
          raise ConnectionError, 'configure' if Native.configure != Native::OK
          raise ConnectionError, "load #{Native.kiln_db_load_error}" if Native.load_kind(kind) != Native::OK
        end

        def create_handle(kind, endpoint)
          opened = Native.open_conn(kind, 1, 1)
          raise ConnectionError, 'open' if opened[0].zero? || opened[1] != Native::OK

          handle = opened[0]
          rc = Native.connect_params(handle, 1, 1, endpoint)
          return handle if rc == Native::OK

          Native.drive(handle, 1, 1, Native::OP_CLOSE, Native.now_ms + 1000)
          raise ConfigError, "connection parameters rejected (code #{rc})"
        end
      end
    end
  end
end
