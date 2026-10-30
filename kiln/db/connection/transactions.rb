module Kiln
  module DB
    class Conn
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
          release_waiter
          out = Native.drive(@handle, 1, 1, Native::OP_CLOSE, Native.now_ms + 5000)
          if out[0] != Native::STEP_DONE
            @broken = true
            raise OwnershipError.new("close #{Native.kiln_db_error_text(@handle, 1, 1)}", code: out[4])
          end
          @closed = true
          nil
        end

        def release_waiter
          waiter = @waiter
          @waiter = nil
          waiter&.close
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

        def affected_rows
          Native.result_meta(@handle, 1, 1)[3]
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
    end
  end
end
