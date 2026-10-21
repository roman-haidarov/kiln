module Kiln
  module DB
    class Pool
      def initialize(size_or_conn = 4, timeout: 1.0, &factory)
        @timeout = timeout
        @single = nil
        @factory = factory
        size = 1
        if size_or_conn.is_a?(Conn)
          @single = size_or_conn
        else
          size = checked_size(size_or_conn, factory)
        end
        @base = build_base(size)
      end

      def size
        @base.size
      end

      def with(timeout: nil)
        conn = checkout(timeout)
        failed = nil
        begin
          yield conn
        rescue *Kiln::Runtime::ERRORS => e
          failed = e
          raise
        ensure
          checkin(conn, failed)
        end
      end

      def checkout(timeout = nil)
        conn = acquire_one(timeout.nil? ? @timeout : timeout)
        begin
          conn.claim!
        rescue *Kiln::Runtime::ERRORS => e
          @base.release(conn, e)
          raise
        end
        conn
      end

      def acquire_one(timeout)
        @base.acquire(timeout: timeout)
      rescue IOError => e
        raise ConnectionError, e.message.to_s
      end

      def checkin(conn, failed = nil)
        err = failed
        err = ConnectionError.new('unhealthy connection') unless healthy?(conn)
        conn.release_claim!
        @base.release(conn, err)
      end

      def healthy?(conn)
        !conn.broken? && conn.depth.zero?
      end

      def discard_error?(err)
        return false if err.nil?

        err.is_a?(ConnectionError) || err.is_a?(Timeout) || err.is_a?(UnknownCommitOutcome) ||
          err.is_a?(OwnershipError) || err.is_a?(Kiln::Runtime::DeadlineExceeded)
      end

      def open_one
        unless @single.nil?
          conn = @single
          @single = nil
          return conn
        end
        raise ConnectionError, 'the pooled connection was discarded' unless @factory

        conn = @factory.call
        raise ArgumentError, 'pool factory must return a Kiln::DB::Conn' unless conn.is_a?(Conn)

        conn
      end

      def opened
        @base.size - @base.available + @base.idle
      end

      def idle
        @base.idle
      end

      def close(timeout: 5.0)
        @base.shutdown(timeout: timeout)
      end

      private

      def checked_size(size, factory)
        raise ArgumentError, 'pool size' unless size.is_a?(Integer) && size.positive?
        raise ArgumentError, 'pool needs a connection factory' unless factory

        size
      end

      def build_base(size)
        ::Kiln::Runtime::Pool.new(size,
                                  discard: ->(err) { discard_error?(err) },
                                  validate: ->(conn) { healthy?(conn) },
                                  close: lambda(&:close)) do
          open_one
        end
      end
    end
  end
end
