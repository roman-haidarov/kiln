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
      OPEN_KEYS = %i[tls timeout].freeze

      module Opening
        def open(kind, host, port, *auth, **options)
          raise Unsupported, 'Kiln::DB on an inline event-loop handler' if Thread.current[:kiln_inline]

          check_open(auth, options)
          endpoint = build_endpoint(kind, host, port, auth, options.fetch(:tls, :verify_full))
          timeout = options.fetch(:timeout) { DEFAULT_TIMEOUT }
          raise ConfigError, 'timeout' unless timeout.is_a?(Numeric) && timeout.positive?

          connect(kind, endpoint, timeout)
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
          constraint_error(code) || access_error(code) || setup_error(code)
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

        def connect(kind, endpoint, timeout)
          prepare_native(kind)
          conn = new(kind, create_handle(kind, endpoint), endpoint.database)
          conn.timeout = timeout
          conn.establish(endpoint.host)
          conn
        end

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

        def constraint_error(code)
          case code
          when Native::DEADLOCK then Deadlock
          when Native::SERIAL then SerializationFailure
          when Native::UNIQUE then UniqueViolation
          when Native::FK then ForeignKeyViolation
          when Native::NOTNULL then NotNullViolation
          when Native::CHECK then CheckViolation
          end
        end

        def access_error(code)
          case code
          when Native::LOCKWAIT then LockWaitTimeout
          when Native::CAPACITY then CapacityError
          when Native::UNSUPPORTED then Unsupported
          when Native::CONN then ConnectionError
          end
        end

        def setup_error(code)
          case code
          when Native::OWNERSHIP, Native::BUSY then OwnershipError
          when Native::CONFIG then ConfigError
          when Native::STALE then StaleView
          else Error
          end
        end
      end

      module Ownership
        def claim!
          @owner_lock.synchronize do
            if !@owner_thread.nil? && !@owner_thread.equal?(Thread.current)
              raise OwnershipError, 'connection is owned by another thread'
            end
            raise ConnectionError, 'connection closed' if @closed

            @owner_thread = Thread.current
            @owner_count += 1
          end
          self
        end

        def release_claim!
          @owner_lock.synchronize do
            unless @owner_thread.equal?(Thread.current) && @owner_count.positive?
              raise OwnershipError, 'connection released by a non-owner'
            end

            @owner_count -= 1
            @owner_thread = nil if @owner_count.zero?
          end
          nil
        end

        def assert_owner!
          @owner_lock.synchronize do
            if !@owner_thread.nil? && !@owner_thread.equal?(Thread.current)
              raise OwnershipError, 'connection owned by another thread'
            end
          end
          nil
        end
      end

      module Running
        def exec(sql, binds)
          assert_owner!
          raise ArgumentError, 'sql' unless sql.is_a?(String)
          raise PoisonedTransaction, 'transaction was rolled back by the server' if @poisoned && @depth.positive?

          text = sql.to_s
          run_sql(text, binds)
        end

        def run_sql(sql, binds)
          cursor_free!
          claim!
          begin
            binds = [] if binds.nil?
            usable!
            return run_pg(sql, binds) if @kind == Native::KIND_PG

            run_my(sql, binds)
          ensure
            release_claim!
          end
        end

        def run_pg(sql, binds)
          load_sql(sql)
          bind_all(binds)
          drive(Native::OP_EXEC, 'exec')
          take_rows('exec')
        end

        def run_my(sql, binds)
          load_sql(sql)
          return run_unprepared(sql) unless prepared?(binds)

          bind_all(binds)
          drive(Native::OP_EXEC, 'exec')
          take_rows('exec')
        end

        def prepared?(binds)
          drive(Native::OP_PREPARE, 'prepare')
          true
        rescue Unsupported
          raise if binds.length.positive?

          false
        end

        def run_unprepared(sql)
          load_sql(sql)
          drive(Native::OP_EXEC, 'exec')
          take_rows('exec')
        end

        def load_sql(sql, chunk = 0)
          raise ConnectionError, 'sql' if Native.set_format(@handle, 1, 1, 0, chunk) != Native::OK
          raise ConnectionError, 'sql' if Native.set_sql(@handle, 1, 1, sql) != Native::OK
        end

        def bind_all(binds)
          i = 0
          while i < binds.length
            bind_one(i, binds[i])
            i += 1
          end
        end

        def bind_one(index, value)
          encoded = Codec.encode(@dialect, value)
          rc = Native.bind_str(@handle, 1, 1, index, encoded)
          raise CapacityError.new("bind #{index}", code: rc) if rc == Native::CAPACITY
          raise ConnectionError.new("bind #{index}", code: rc) if rc != Native::OK
        end

        def take_rows(label)
          rows = []
          loop do
            meta = Native.result_meta(@handle, 1, 1)
            append_rows(rows, meta[0], meta[1])
            break if meta[2] == 1

            drive(Native::OP_DRAIN, label)
          end
          rows
        end

        def append_rows(rows, width, count)
          return unless count.positive? && width.positive?

          types = Native.result_types(@handle, 1, 1, width)
          lens = Array.new(width, 0)
          r = 0
          while r < count
            rows << Codec.row(Native.result_row(@handle, 1, 1, r, lens), lens, types, width)
            r += 1
          end
        end
      end

      module Transactions
        def transaction_open
          cursor_free!
          usable!
          if @depth.zero?
            drive(Native::OP_BEGIN, 'begin')
            take_rows('begin')
            @poisoned = false
          else
            run_sql("SAVEPOINT kiln_sp_#{@depth}", [])
          end
          @depth += 1
        end

        def transaction_ok
          raise Error, 'no transaction' if @depth <= 0

          cursor_free!
          if @depth == 1
            @depth = 0
            commit_now
          else
            @depth -= 1
            run_sql("RELEASE SAVEPOINT kiln_sp_#{@depth}", [])
          end
        end

        def commit_now
          drive(Native::OP_COMMIT, 'commit')
          take_rows('commit')
        rescue Error => e
          raise unless lost?(e)

          @broken = true
          raise UnknownCommitOutcome.new("commit outcome unknown: #{e.message}", code: e.code)
        end

        def transaction_fail
          return nil if @depth <= 0

          stream_close
          @depth == 1 ? rollback_all : rollback_savepoint
          nil
        end

        def rollback_all
          @depth = 0
          @poisoned = false
          drive(Native::OP_ROLLBACK, 'rollback')
          take_rows('rollback')
        rescue Error
          @broken = true
        end

        def rollback_savepoint
          @depth -= 1
          run_sql("ROLLBACK TO SAVEPOINT kiln_sp_#{@depth}", [])
        rescue Error => e
          @broken = true if lost?(e)
          @poisoned = true
        end

        def lost?(err)
          err.is_a?(ConnectionError) || err.is_a?(Timeout) || err.is_a?(OwnershipError) || broken?
        end

        def close
          assert_owner!
          return nil if @closed

          stream_close
          out = Native.drive(@handle, 1, 1, Native::OP_CLOSE, Native.now_ms + 5000)
          if out[0] != Native::STEP_DONE
            @broken = true
            raise OwnershipError.new("close #{Native.kiln_db_error_text(@handle, 1, 1)}", code: out[4])
          end
          @closed = true
          nil
        end

        def close_quietly
          close
        rescue Error
          nil
        end
      end

      module Pipeline
        def pipelined?
          @pipelined == true
        end

        def warning_count
          Native.result_meta(@handle, 1, 1)[4]
        end

        def pipeline_begin
          cursor_free!
          drive(Native::OP_PIPELINE_ENTER, 'pipeline')
          @pipelined = true
        end

        def pipeline_finish
          drive(Native::OP_PIPELINE_EXIT, 'pipeline')
          @pipelined = false
        end

        def pipeline_exec(sql, binds)
          raise Error, 'pipeline' unless pipelined?

          binds = [] if binds.nil?
          text = sql.to_s
          load_sql(text)
          bind_all(binds)
          drive(Native::OP_PIPELINE_QUERY, 'pipeline')
          nil
        end

        def pipeline_sync
          drive(Native::OP_PIPELINE_SYNC, 'pipeline')
          nil
        end

        def pipeline_read
          drive(Native::OP_PIPELINE_TAKE, 'pipeline')
          meta = Native.result_meta(@handle, 1, 1)
          raise Error, 'pipeline sync' if meta[4] == 1

          take_rows('pipeline')
        end

        def pipeline_sync_read
          drive(Native::OP_PIPELINE_TAKE, 'pipeline')
          meta = Native.result_meta(@handle, 1, 1)
          raise Error, 'pipeline result' if meta[4] != 1

          nil
        end

        def abandon_pipeline
          pipeline_finish
        rescue Error
          @broken = true
        end

        def pipeline_batch(queries)
          pipeline_begin
          begin
            send_batch(queries)
            out, err = read_batch(queries)
            pipeline_finish
          ensure
            abandon_pipeline if pipelined?
          end
          raise err if err

          out
        end

        def send_batch(queries)
          i = 0
          while i < queries.length
            query = queries[i]
            unless query.nil?
              pipeline_exec(query[0], query[1])
              pipeline_sync
            end
            i += 1
          end
        end

        def read_batch(queries)
          out = []
          err = nil
          i = 0
          while i < queries.length
            rows, failure = queries[i].nil? ? [nil, nil] : read_one
            out << rows
            err ||= failure
            i += 1
          end
          [out, err]
        end

        def read_one
          rows = nil
          failure = nil
          begin
            rows = pipeline_read
          rescue Error => e
            failure = e
          end
          [rows, sync_failure(failure)]
        end

        def sync_failure(failure)
          pipeline_sync_read
          failure
        rescue Error => e
          failure || e
        end
      end

      module Driving
        def usable!
          raise ConnectionError, 'connection closed' if @closed
          raise ConnectionError, 'connection broken; discard it' if @broken
        end

        def deadline_ms
          now = Native.now_ms
          limit = now + @timeout_ms
          stamp = Thread.current[:kiln_deadline]
          if !stamp.nil? && stamp.positive?
            left = ((stamp - Process.clock_gettime(Process::CLOCK_MONOTONIC)) * 1000).to_i
            raise Timeout.new('request deadline exceeded', code: Native::TIMEOUT) if left <= 0

            limit = now + left if now + left < limit
          end
          limit
        end

        def drive(operation, label)
          assert_owner!
          raise Unsupported, 'Kiln::DB on an inline event-loop handler; use handlers: N' if Thread.current[:kiln_inline]

          out = Native.drive(@handle, 1, 1, operation, deadline_ms)
          return out if out[0] == Native::STEP_DONE

          fail_step(out, label, operation)
        end

        def fail_step(out, label, operation)
          code = out[4]
          text = "#{label} #{Native.kiln_db_error_text(@handle, 1, 1)}"
          state = Conn.sqlstate(out[5])
          if code == Native::TIMEOUT
            recover_timeout(operation)
            raise Timeout.new(text, sqlstate: state, code: code)
          end
          @broken = true if [Native::CONN, Native::OWNERSHIP, Native::BUSY].include?(code)
          @broken = true if Native.broken?(@handle, 1, 1)
          raise Conn.error_class(code).new(text, sqlstate: state, code: code)
        end

        def recover_timeout(operation)
          if operation == Native::OP_CONNECT || @kind != Native::KIND_PG
            @broken = true
            return nil
          end
          out = Native.drive(@handle, 1, 1, Native::OP_CANCEL, Native.now_ms + CANCEL_MS)
          @broken = true if out[0] != Native::STEP_DONE || Native.broken?(@handle, 1, 1)
          nil
        end
      end

      module Streaming
        def streaming?
          @cursor_open == true
        end

        def cursor_free!
          raise Error, 'a streaming query is open on this connection' if @cursor_open == true
        end

        def each_row(sql, binds)
          stream_open(sql, binds)
          begin
            while (row = stream_next)
              yield row
            end
          ensure
            stream_close
          end
          nil
        end

        def stream_open(sql, binds)
          assert_owner!
          raise ArgumentError, 'sql' unless sql.is_a?(String)

          cursor_free!
          raise PoisonedTransaction, 'transaction was rolled back by the server' if @poisoned && @depth.positive?

          usable!
          claim!
          start_stream(sql.to_s, binds || [])
          nil
        end

        def start_stream(text, binds)
          opened = false
          load_sql(text, @kind == Native::KIND_PG ? 256 : 0)
          load_sql(text) if @kind == Native::KIND_MY && !prepared?(binds)
          bind_all(binds)
          drive(Native::OP_EXEC, 'exec')
          @cursor_open = true
          cursor_meta
          opened = true
        ensure
          abort_open unless opened
        end

        def stream_next
          while @cursor_open == true
            row = @cursor_row
            if row < @cursor_count
              @cursor_row = row + 1
              lens = @cursor_lens
              return Codec.row(Native.result_row(@handle, 1, 1, row, lens), lens, @cursor_types, @cursor_width)
            end
            stream_more?
          end
          nil
        end

        def stream_more?
          if @cursor_done
            cursor_finish
            return false
          end
          fetch_more
          cursor_meta
          true
        end

        def fetch_more
          fetched = false
          drive(Native::OP_DRAIN, 'fetch')
          fetched = true
        ensure
          abort_fetch unless fetched
        end

        def stream_close
          return nil unless @cursor_open == true

          begin
            cursor_abandon unless @cursor_done
          ensure
            cursor_finish
          end
          nil
        end
      end

      module Cursor
        def abort_open
          @broken = true if Native.broken?(@handle, 1, 1)
          @cursor_open = false
          release_claim!
        end

        def cursor_meta
          meta = Native.result_meta(@handle, 1, 1)
          @cursor_width = meta[0]
          @cursor_count = meta[0].positive? ? meta[1] : 0
          @cursor_done = meta[2] == 1
          @cursor_row = 0
          if @cursor_count.positive?
            @cursor_types = Native.result_types(@handle, 1, 1, @cursor_width)
            @cursor_lens = Array.new(@cursor_width, 0)
          end
          nil
        end

        def abort_fetch
          @broken = true if @kind == Native::KIND_MY || Native.broken?(@handle, 1, 1)
          cursor_finish
        end

        def cursor_finish
          return nil unless @cursor_open == true

          @cursor_open = false
          @cursor_count = 0
          @cursor_row = 0
          release_claim!
          nil
        end

        def cursor_abandon
          stop = Native.now_ms + CANCEL_MS
          operation = @kind == Native::KIND_PG ? Native::OP_CANCEL : Native::OP_DRAIN
          loop { break if abandon_step?(operation, stop) }
          nil
        end

        def abandon_step?(operation, stop)
          out = Native.drive(@handle, 1, 1, operation, stop)
          return mark_broken if out[0] != Native::STEP_DONE || Native.broken?(@handle, 1, 1)
          return true if Native.result_meta(@handle, 1, 1)[2] == 1
          return mark_broken if Native.now_ms >= stop

          false
        end

        def mark_broken
          @broken = true
        end
      end

      extend Opening
      include Ownership
      include Running
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

      def establish(host)
        connected = false
        begin
          resolve_host(host) if @kind == Native::KIND_PG
          drive(Native::OP_CONNECT, 'connect')
          detect_server
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
        resolved = Native.pg_hostaddr(host, deadline_ms)
        raise ConnectionError, 'hostaddr' unless Native.set_hostaddr(@handle, 1, 1, resolved) == Native::OK
      end

      def init_flags
        @depth = 0
        @pipelined = false
        @broken = false
        @poisoned = false
        @closed = false
        @mariadb = false
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
      end
    end
  end
end
