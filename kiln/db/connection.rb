require 'kiln/db/connection/opening'
require 'kiln/db/connection/ownership'
require 'kiln/db/connection/query'
require 'kiln/db/connection/transactions'
require 'kiln/db/connection/driving'
require 'kiln/db/connection/cursor'

module Kiln
  module DB
    class Endpoint
      attr_reader :host, :port, :user, :password, :database, :ssl_mode, :ca_path, :tls_name

      def initialize(host, port, credentials)
        @host = host
        @port = port
        @user = credentials[0]
        @password = credentials[1]
        @database = credentials[2]
        secure(Native::SSL_VERIFY_FULL, '', '')
      end

      def secure(ssl_mode, ca_path, tls_name)
        @ssl_mode = ssl_mode
        @ca_path = ca_path
        @tls_name = tls_name
        self
      end

      def apply_to(handle, scope, thread_id)
        insecure = @ssl_mode == Native::SSL_DISABLE ? 1 : 0
        Native.kiln_db_conn_set(handle, scope, thread_id, @host, @host.bytesize, @port, @user, @user.bytesize,
                                @password, @password.bytesize, @database, @database.bytesize, @ssl_mode,
                                @ca_path, @ca_path.bytesize, insecure, @tls_name, @tls_name.bytesize)
      end
    end

    class Conn
      DEFAULT_TIMEOUT = 15.0
      CANCEL_MS = 2000
      OPEN_KEYS = %i[tls timeout statement_cache].freeze
      BATCH_ROWS = 256
      BATCH_BYTES = 1_048_576

      extend Opening
      include Ownership
      include Running
      include Fetching
      include Copying
      include Transactions
      include Pipeline
      include Driving
      include Streaming
      include Cursor

      attr_reader :kind, :dialect, :schema_name, :handle, :depth

      def initialize(kind, handle, database)
        @kind = kind
        @handle = handle
        @database = database
        @dialect = kind == Native::KIND_PG ? :postgres : :mysql
        @schema_name = kind == Native::KIND_PG ? 'public' : database
        @timeout_ms = (DEFAULT_TIMEOUT * 1000).to_i
        init_flags
        init_owner
        init_cursor
      end

      def establish(host, cache)
        connected = false
        begin
          resolve_host(host) if @kind == Native::KIND_PG
          drive(Native::OP_CONNECT, 'connect')
          detect_server
          raise ConnectionError, 'statement_cache' if Native.set_stmt_cache(@handle, 1, 1, cache) != Native::OK

          @waiter = SocketWait.new
          connected = true
        ensure
          close_quietly unless connected
        end
      end

      def timeout=(seconds)
        @timeout_ms = (seconds * 1000).to_i
      end

      def mariadb?
        @mariadb
      end

      def broken?
        return true if @broken || @closed

        if Native.broken?(@handle, 1, 1)
          @broken = true
          return true
        end
        false
      end

      def detect_server
        return nil if @kind != Native::KIND_MY

        rows = run_sql('SELECT VERSION()', [])
        version = rows.length.positive? ? rows[0][0].to_s : ''
        @mariadb = version.include?('MariaDB')
        nil
      end

      private

      def resolve_host(host)
        resolved = Native.pg_hostaddr(@handle, host, deadline_ms)
        raise ConnectionError, 'hostaddr' unless Native.set_hostaddr(@handle, 1, 1, resolved) == Native::OK
      end

      def init_flags
        @depth = 0
        @pipelined = false
        @broken = false
        @poisoned = false
        @closed = false
        @mariadb = false
        @waiter = nil
      end

      def init_owner
        @owner_lock = Mutex.new
        @owner_thread = nil
        @owner_count = 0
      end

      def init_cursor
        @cursor_open = false
        @cursor_done = true
        @cursor_width = 0
        @cursor_count = 0
        @cursor_row = 0
        @cursor_types = Array.new(1, 0)
        @cursor_lens = Array.new(1, 0)
        @cursor_left = 0
        @cursor_batch = RowBatch.new(@cursor_lens, 1)
        @cursor_off = @cursor_at = 0
      end
    end
  end
end
