module Kiln
  module DB
    class ScopeSlot
      def initialize
        @conn = nil
      end

      attr_accessor :conn
    end

    module Scope
      class << self
        def slot
          found = Thread.current[:kiln_db_scope]
          return found if found.is_a?(ScopeSlot)

          made = ScopeSlot.new
          Thread.current[:kiln_db_scope] = made
          made
        end

        def use(conn)
          cell = slot
          old = cell.conn
          return conn if old.equal?(conn)

          conn&.claim!
          old&.release_claim!
          cell.conn = conn
          conn
        end

        def current
          slot.conn
        end

        def pool=(value)
          raise ArgumentError, 'pool must be a Kiln::DB::Pool' unless value.nil? || value.is_a?(Kiln::DB::Pool)

          @pool = value
        end

        def hold(conn)
          cell = slot
          prior = cell.conn
          conn.claim!
          cell.conn = conn
          begin
            yield
          ensure
            cell.conn = prior
            conn.release_claim!
          end
        end

        def lease(&)
          with_conn(false, &)
        end

        def transaction(&)
          with_conn(true, &)
        end

        private

        def with_conn(transactional, &)
          held = slot.conn
          return use_conn(held, transactional, &) if held

          raise ConnectionError, 'no connection: set Kiln::DB::Scope.pool' if @pool.nil?

          leased(transactional, &)
        end

        def use_conn(conn, transactional, &)
          transactional ? run_transaction(conn, &) : yield(conn)
        end

        def leased(transactional, &)
          pool, conn = open_lease
          failed = nil
          use_conn(conn, transactional, &)
        rescue *Kiln::Runtime::ERRORS => e
          failed = e
          raise
        ensure
          close_lease(pool, conn, failed) if conn
        end

        def open_lease
          pool = @pool
          conn = pool.checkout
          slot.conn = conn
          [pool, conn]
        end

        def close_lease(pool, conn, failed)
          slot.conn = nil
          pool.checkin(conn, failed)
        end

        def run_transaction(conn)
          conn.transaction_open
          done = false
          result = yield conn
          done = true
          conn.transaction_ok
          result
        ensure
          conn.transaction_fail if done == false
        end
      end
    end

    class << self
      def transaction(&)
        Scope.transaction(&)
      end
    end
  end
end
