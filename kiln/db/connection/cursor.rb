module Kiln
  module DB
    class Conn
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
            return next_streamed if @cursor_row < @cursor_count

            stream_more?
          end
          nil
        end

        def next_streamed
          load_stream_batch if @cursor_left.zero?
          at = @cursor_at * (@cursor_width + 1)
          values = Codec.row_values(@cursor_batch, at, @cursor_off, @cursor_types)
          @cursor_off += @cursor_lens[at + @cursor_width]
          @cursor_at += 1
          @cursor_row += 1
          @cursor_left -= 1
          values
        end

        def load_stream_batch
          meta = [0, 0, 0]
          @cursor_batch = fetch_rows(@cursor_row, @cursor_lens, meta)
          @cursor_off = @cursor_at = 0
          @cursor_left = meta[0]
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
          @cursor_left = 0
          cursor_shape if @cursor_count.positive?
          nil
        end

        def cursor_shape
          @cursor_types = Native.result_types(@handle, 1, 1, @cursor_width)
          @cursor_lens = Array.new(BATCH_ROWS * (@cursor_width + 1), 0)
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
    end
  end
end
