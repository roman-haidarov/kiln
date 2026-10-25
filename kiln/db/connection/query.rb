module Kiln
  module DB
    class Conn
      module Running
        def exec(sql, binds)
          check_query(sql)
          run_sql(sql.to_s, binds)
        end

        def pluck_column(sql, binds)
          check_query(sql)
          run_sql(sql.to_s, binds, column: true)
        end

        def check_query(sql)
          assert_owner!
          raise ArgumentError, 'sql' unless sql.is_a?(String)
          raise PoisonedTransaction, 'transaction was rolled back by the server' if @poisoned && @depth.positive?
        end

        def run_sql(sql, binds, column: false)
          cursor_free!
          claim!
          begin
            binds = [] if binds.nil?
            usable!
            return run_pg(sql, binds, column: column) if @kind == Native::KIND_PG

            run_my(sql, binds, column: column)
          ensure
            release_claim!
          end
        end

        def run_pg(sql, binds, column: false)
          load_sql(sql)
          bind_all(binds)
          drive(Native::OP_EXEC, 'exec')
          column ? take_column('exec') : take_rows('exec')
        end

        def run_my(sql, binds, column: false)
          load_sql(sql)
          return run_unprepared(sql, column: column) unless prepared?(binds)

          bind_all(binds)
          drive(Native::OP_EXEC, 'exec')
          column ? take_column('exec') : take_rows('exec')
        end

        def prepared?(binds)
          drive(Native::OP_PREPARE, 'prepare')
          true
        rescue Unsupported
          raise if binds.length.positive?

          false
        end

        def run_unprepared(sql, column: false)
          load_sql(sql)
          drive(Native::OP_EXEC, 'exec')
          column ? take_column('exec') : take_rows('exec')
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
      end

      module Fetching
        def take_rows(label)
          take_result(label, false)
        end

        def row_batch(lens)
          size = lens.length
          @row_batch = RowBatch.new(lens, size) if @row_batch.nil? || @row_batch.nums.length < size
          @row_batch
        end

        def fetch_rows(first, lens, meta)
          batch = row_batch(lens)
          raw = Native.kiln_db_result_rows_typed(@handle, 1, 1, first, BATCH_ROWS, BATCH_BYTES, lens, lens.length,
                                                 batch.nums, batch.floats, meta, meta.length)
          raise ConnectionError, 'database rows unavailable or invalid' unless meta[0].positive?

          batch.load(raw, lens)
        end

        def append_rows(rows, width, count)
          append_result(rows, width, count, false)
        end

        def take_column(label)
          take_result(label, true)
        end

        def append_column(values, width, count)
          append_result(values, width, count, true)
        end

        def take_result(label, column)
          values = []
          loop do
            meta = Native.result_meta(@handle, 1, 1)
            append_result(values, meta[0], meta[1], column)
            break if meta[2] == 1

            drive(Native::OP_DRAIN, label)
          end
          values
        end

        def append_result(values, width, count, column)
          return unless count.positive? && width.positive?

          types = Native.result_types(@handle, 1, 1, width)
          lens = Array.new(BATCH_ROWS * (width + 1), 0)
          meta = [0, 0, 0]
          r = 0
          while r < count
            batch = fetch_rows(r, lens, meta)
            if column
              Codec.column_into(values, batch, types, meta[0])
            else
              Codec.rows_into(values, batch, types, meta[0])
            end
            r += meta[0]
          end
        end
      end

      module Copying
        def copy_in(sql, payload, rows)
          check_query(sql)
          cursor_free!
          claim!
          begin
            copy_payload(sql, payload, rows)
          ensure
            release_claim!
          end
        end

        def copy_payload(sql, payload, rows)
          usable!
          raise ConnectionError, 'sql' if Native.set_sql(@handle, 1, 1, sql) != Native::OK

          rc = Native.set_copy(@handle, 1, 1, payload)
          raise CapacityError.new('copy', code: rc) if rc == Native::CAPACITY
          raise ConnectionError.new('copy', code: rc) if rc != Native::OK

          out = drive(Native::OP_COPY_IN, 'copy')
          raise InvariantViolation, 'copy' unless out[7] == rows

          nil
        end
      end
    end
  end
end
