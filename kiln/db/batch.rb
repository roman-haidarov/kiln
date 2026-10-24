module Kiln
  module DB
    class ImportMode
      attr_reader :skip_conflicts, :update_conflicts, :return_rows

      def initialize(ignore, update, returning)
        @skip_conflicts = ignore
        @update_conflicts = update
        @return_rows = returning
      end
    end

    class ImportPage
      attr_reader :originals, :from, :upto
      attr_accessor :base

      def initialize(originals, from, upto)
        @originals = originals
        @from = from
        @upto = upto
        @base = 0
      end
    end

    class KeyChain
      def initialize(first, size, newest_first)
        @first = first
        @newest_first = newest_first
        @heads = {}
        @tails = {}
        @nexts = Array.new(size, -1)
        @seen = {}
      end

      def link(key, index)
        if !@heads.key?(key)
          @heads[key] = index
          @tails[key] = index
        elsif @newest_first
          @nexts[index - @first] = @heads[key]
          @heads[key] = index
        else
          @nexts[@tails[key] - @first] = index
          @tails[key] = index
        end
      end

      def claim_index(key)
        return -1 unless @heads.key?(key)

        index = @heads[key]
        return index if index.negative?

        @seen[key] = true
        @heads[key] = @nexts[index - @first]
        index
      end

      def seen?(key) = @seen.key?(key)
    end

    class Batch
      module Writing
        private

        def write_masks(conn, masks)
          raise InvariantViolation, 'pipeline' if conn.pipelined?

          @state = 'PENDING_COMMIT' if conn.depth > 1
          alias_rows = @model.dialect != :postgres && !conn.mariadb?
          prove_writes(conn)
          i = 0
          while i < masks.length
            write_part(conn, masks[i], alias_rows)
            i += 1
          end
          nil
        end

        def prove_writes(conn)
          prove_mysql(conn) if @model.dialect != :postgres
          Schema.prove_stable_keys(conn, @model.table_name, @update) if @returning
        end

        def prove_mysql(conn)
          Import.prove_session(conn)
          Schema.prove_update_key(conn, @model) if @update
        end

        def write_part(conn, part, alias_rows)
          shape = copy_shape_for(conn, part[2])
          return write_copy(conn, part, shape.positive? ? Import.copy_stamp(conn) : nil) unless shape.negative?

          step = Import.page_rows(part[1].length)
          offset = 0
          while offset < part[2].length
            write_page(conn, part, offset, step, alias_rows)
            offset += step
          end
        end

        def copy_shape_for(conn, rows)
          shape = Import.copy_shape(@model.dialect, @mode, rows)
          return shape if shape.negative?

          @copy_table = Schema.copy_table?(conn, @model.table_name) ? 1 : -1 if @copy_table.zero?
          @copy_table.positive? ? shape : -1
        end

        def write_copy(conn, part, stamp)
          rows = part[2]
          offset = 0
          sql = Import.copy_sql(@model, part[1])
          while offset < rows.length
            payload, count = Import.copy_chunk(rows, offset, Import::COPY_LIMIT, stamp)
            conn.copy_in(sql, payload, count)
            mark_inserted(ImportPage.new(part[3], offset, offset + count))
            offset += count
          end
        end

        def write_page(conn, part, offset, step, alias_rows)
          sql, binds = Import.insert_sql(@model, Import.page_part(part, offset, step), @mode, alias_rows)
          got = conn.exec(sql, binds)
          raise Error, 'warnings' if @model.dialect != :postgres && conn.warning_count.positive?

          page = ImportPage.new(part[3], offset, [offset + step, part[2].length].min)
          check_affected(conn, page)
          @returning ? record_returned(conn, got, page) : mark_inserted(page)
        end

        def mark_inserted(page)
          value = @ignore || @update ? 'applied_unknown' : 'inserted'
          j = page.from
          while j < page.upto
            @status[page.originals[j]] = value
            j += 1
          end
        end

        def record_returned(conn, got, page)
          got = read_back(conn, page) if @model.dialect != :postgres
          page.base = @found_rows.length
          store_found(got)
          match_page(conn, page, got)
        end

        def store_found(got)
          i = 0
          while i < got.length
            @found_rows << got[i]
            @orphaned << false
            i += 1
          end
        end

        def read_back(conn, page)
          dialect = @model.dialect
          key = @model.primary_key[0]
          binds = []
          marks = key_marks(page, key, binds)
          list = Import.returning_list(dialect, @model)
          table = Sql.quote(dialect, @model.table_name)
          conn.exec("SELECT #{list} FROM #{table} WHERE #{Sql.quote(dialect, key)} IN (#{marks})", binds)
        end

        def key_marks(page, key, binds)
          marks = []
          j = page.from
          while j < page.upto
            binds << Import.field(Import.row_hash(@rows[page.originals[j]]), key)[1]
            marks << Sql.placeholder(@model.dialect, binds)
            j += 1
          end
          marks.join(', ')
        end
      end

      module Canonical
        private

        def check_affected(conn, page)
          return unless @model.dialect == :postgres && !@ignore && !@update && !@returning

          raise InvariantViolation, 'import affected rows' if conn.affected_rows != page.upto - page.from
        end

        def input_keys(page)
          keys = []
          j = page.from
          while j < page.upto
            keys << Import.input_key(@model, @rows[page.originals[j]])
            j += 1
          end
          keys
        end

        def resolved_keys(conn, page, keys, got)
          return {} if got.empty?

          returned = {}
          got.each { |row| returned[Import.output_key(@model, row)] = true }
          firsts = unmatched_inputs(page, keys, returned)
          firsts.empty? ? {} : lookup_keys(conn, firsts)
        end

        def unmatched_inputs(page, keys, returned)
          firsts = {}
          i = 0
          while i < keys.length
            key = keys[i]
            firsts[key] = page.originals[page.from + i] unless returned.key?(key) || firsts.key?(key)
            i += 1
          end
          firsts
        end

        def lookup_keys(conn, firsts)
          texts = firsts.keys
          binds = []
          parts = []
          texts.each_with_index { |text, at| parts << lookup_part(at, Import.row_hash(@rows[firsts[text]]), binds) }
          resolved = {}
          conn.exec(parts.join(' UNION ALL '), binds).each { |found| resolve_found(resolved, texts, found) }
          resolved
        end

        def resolve_found(resolved, texts, found)
          text = texts[found[0].to_s.to_i]
          raise UnsupportedReturn, 'returning: non-unique key' if resolved.key?(text)

          resolved[text] = found.drop(1).map { |value| Import.sized_text(value.to_s) }.join
        end

        def lookup_part(at, row, binds)
          dialect = @model.dialect
          keys = @model.primary_key
          terms = keys.map do |key|
            binds << Import.field(row, key)[1]
            "#{Sql.quote(dialect, key)} = #{Sql.placeholder(dialect, binds)}"
          end
          names = keys.map { |key| Sql.quote(dialect, key) }.join(', ')
          "(SELECT #{at} AS kiln_at, #{names} FROM #{Sql.quote(dialect, @model.table_name)} " \
            "WHERE #{terms.join(' AND ')} LIMIT 2)"
        end
      end

      module Matching
        private

        def match_page(conn, page, got)
          chain = key_chain(conn, page, got)
          orphans = claim_rows(page, chain, got)
          left = unpicked(page)
          paired = orphans.length == 1 && left.length == 1
          uneven = orphans.length != left.length
          raise InvariantViolation, 'returning' if uneven && @model.dialect == :postgres && !@ignore

          settle_left(page, left, orphans, paired, chain)
          mark_orphans(page, orphans) unless paired
          mark_picked(page)
          nil
        end

        def key_chain(conn, page, got)
          chain = KeyChain.new(page.from, page.upto - page.from, @update)
          keys = input_keys(page)
          resolved = resolved_keys(conn, page, keys, got)
          j = page.from
          while j < page.upto
            key = keys[j - page.from]
            chain.link(resolved.key?(key) ? resolved[key] : key, j)
            j += 1
          end
          chain
        end

        def claim_rows(page, chain, got)
          orphans = []
          r = 0
          while r < got.length
            j = chain.claim_index(Import.output_key(@model, got[r]))
            orphans << r if j.negative?
            @picks[page.originals[j]] = page.base + r unless j.negative?
            r += 1
          end
          orphans
        end

        def unpicked(page)
          left = []
          j = page.from
          while j < page.upto
            left << j if @picks[page.originals[j]].negative?
            j += 1
          end
          left
        end

        def settle_left(page, left, orphans, paired, chain)
          i = 0
          while i < left.length
            original = page.originals[left[i]]
            if paired
              @picks[original] = page.base + orphans[i]
            else
              @status[original] = left_status(original, orphans, chain)
            end
            i += 1
          end
        end

        def left_status(original, orphans, chain)
          return 'skipped_conflict' if @ignore && skipped?(original, orphans, chain)

          @ignore || @update ? 'applied_unknown' : 'inserted'
        end

        def skipped?(original, orphans, chain)
          orphans.empty? || chain.seen?(Import.input_key(@model, @rows[original]))
        end

        def mark_orphans(page, orphans)
          i = 0
          while i < orphans.length
            @orphaned[page.base + orphans[i]] = true
            i += 1
          end
        end

        def mark_picked(page)
          j = page.from
          while j < page.upto
            original = page.originals[j]
            @status[original] = @update ? 'applied_unknown' : 'inserted' if @picks[original] >= 0
            j += 1
          end
        end
      end

      include Writing
      include Canonical
      include Matching

      def initialize(model, rows, mode)
        @model = model
        @rows = rows
        @mode = mode
        @ignore = mode.skip_conflicts
        @update = mode.update_conflicts
        @returning = mode.return_rows
        init_results(rows.length)
      end

      def write(masks)
        DB.transaction { |conn| write_masks(conn, masks) }
        ImportResult.committed(@status, collect_returned, @state)
      end

      private

      def init_results(count)
        @picks = Array.new(count, -1)
        @status = Array.new(count, 'validation_invalid')
        @found_rows = []
        @orphaned = []
        @copy_table = 0
        @state = 'COMMITTED'
      end

      def collect_returned
        returned = []
        i = 0
        while i < @picks.length
          returned << @found_rows[@picks[i]] if @picks[i] >= 0
          i += 1
        end
        add_orphans(returned)
      end

      def add_orphans(returned)
        i = 0
        while i < @found_rows.length
          returned << @found_rows[i] if @orphaned[i]
          i += 1
        end
        returned
      end
    end

    class ImportResult
      attr_reader :state, :returned

      def initialize(state, status, returned)
        @state = state
        @status = status
        @returned = returned
      end

      def input_status(index)
        @status[index]
      end

      def length
        @status.length
      end

      class << self
        def empty
          new('COMMITTED', [], [])
        end

        def committed(status, returned, state = 'COMMITTED')
          new(state, status, returned)
        end

        def rejected(count)
          status = []
          i = 0
          while i < count
            status << 'validation_invalid'
            i += 1
          end
          new('VALIDATION_REJECTED', status, [])
        end
      end
    end

    module Import
      MAX_PAGE_ROWS = 1000
      MAX_PAGE_PARAMS = 32_767
      COPY_LIMIT = 16 * 1024 * 1024
      OPTION_KEYS = %i[on_duplicate_key_ignore on_duplicate_key_update returning require_exact_status validate
                       validate_uniqueness all_or_none timestamps raise_error].freeze

      module Checks
        def run(model, rows, options, bang)
          options = {} if options.nil?
          raise ArgumentError, 'rows' unless rows.is_a?(Array)
          raise ArgumentError, 'options' unless options.is_a?(Hash)

          check_options(options, bang)
          mode = import_mode(model, rows, options)
          raise InvariantViolation, 'pipeline' if Scope.current&.pipelined?
          return ImportResult.empty if rows.empty?

          write_valid(model, rows, options, bang, mode)
        end

        def check_options(options, bang)
          raise ArgumentError, 'option' unless (options.keys - OPTION_KEYS).empty?
          raise ArgumentError, 'import!' if bang && options[:validate] == false
        end

        def split_rows(rows, bang, validate)
          valid = []
          failed = []
          index = 0
          while index < rows.length
            row = rows[index]
            checked_error(row, validate, bang).nil? ? valid.push([row, index]) : failed.push(index)
            index += 1
          end
          [valid, failed]
        end

        def checked_error(row, validate, bang)
          err = row_error(row, validate)
          raise RecordInvalid, err if err && bang

          err
        end

        def prove_session(conn)
          rows = conn.exec('SELECT @@session.sql_mode, @@session.foreign_key_checks, @@session.unique_checks', [])
          raise UnsafeImportSchema, 'session' unless safe_session?(rows)

          nil
        end

        def keys_ready?(model, rows)
          keys = model.primary_key
          return false if keys.empty?

          rows.all? { |row| row_keys_ready?(row_hash(row), keys) }
        end

        private

        def write_valid(model, rows, options, bang, mode)
          valid, failed = split_rows(rows, bang, options[:validate] != false)
          rejected = failed.length.positive? && options[:all_or_none] != false
          return ImportResult.rejected(rows.length) if rejected || valid.empty?

          Batch.new(model, rows, mode).write(group_rows(model, valid, options[:timestamps] == true))
        end

        def import_mode(model, rows, options)
          ignore = options[:on_duplicate_key_ignore] == true
          update = options[:on_duplicate_key_update] == true
          returning = options[:returning] == true
          check_conflict(model, ignore, update)
          check_exact(options[:require_exact_status] == true, ignore, update, returning)
          check_returning(model, rows) if returning
          ImportMode.new(ignore, update, returning)
        end

        def check_conflict(model, ignore, update)
          raise ArgumentError, 'conflict' if ignore && update
          raise UnsafeImportSchema, 'ignore' if ignore && model.dialect != :postgres
        end

        def check_exact(exact, ignore, update, returning)
          return unless exact && (update || (ignore && !returning))

          raise UnsupportedExactStatus, 'status'
        end

        def check_returning(model, rows)
          raise UnsupportedReturn, 'returning' unless keys_ready?(model, rows)
          raise UnsupportedReturn, 'returning' if model.dialect != :postgres && model.primary_key.length != 1
        end

        def row_error(row, validate) = validate && row.is_a?(Model) ? row.validate : nil

        def safe_session?(rows)
          return false if rows.empty?

          row = rows[0]
          row[0].to_s.include?('STRICT_TRANS_TABLES') && row[1].to_s != '0' && row[2].to_s != '0'
        end

        def row_keys_ready?(row, keys)
          keys.all? do |key|
            found = field(row, key)
            !found.nil? && found[0] != false && !found[1].nil?
          end
        end
      end

      module Rows
        def group_rows(model, entries, timestamps)
          groups = []
          i = 0
          while i < entries.length
            entry = entries[i]
            names, values = fields_of(model.columns, row_hash(entry[0]), timestamps)
            place_mask(groups, names, values, entry[1])
            i += 1
          end
          groups
        end

        def fields_of(columns, row, timestamps)
          names = []
          values = []
          i = 0
          while i < columns.length
            found = column_field(row, columns[i], timestamps)
            names << columns[i] unless found.nil?
            values << found[1] unless found.nil?
            i += 1
          end
          [names, values]
        end

        def column_field(row, name, timestamps)
          found = field(row, name)
          return found unless found.nil?
          return [true, :timestamp] if timestamps && %w[created_at updated_at].include?(name)

          nil
        end

        def field(row, name)
          text = row.key?(name)
          symbol = row.key?(name.to_sym)
          raise ArgumentError, 'key' if text && symbol
          return [true, row[name]] if text
          return [true, row[name.to_sym]] if symbol

          nil
        end

        def place_mask(groups, names, values, original_index)
          key = mask_key(names)
          last = groups.length - 1
          if last >= 0 && groups[last][0] == key
            groups[last][2] << values
            groups[last][3] << original_index
          else
            groups << [key, names, [values], [original_index]]
          end
        end

        def mask_key(names) = names.join(',')

        def page_rows(width)
          return MAX_PAGE_ROWS if width <= 0

          rows = MAX_PAGE_PARAMS / width
          rows = MAX_PAGE_ROWS if rows > MAX_PAGE_ROWS
          raise CapacityError, 'binds' if rows < 1

          rows
        end

        def page_part(part, offset, step)
          matrix = []
          i = offset
          last = offset + step
          last = part[2].length if last > part[2].length
          while i < last
            matrix << part[2][i]
            i += 1
          end
          [part[0], part[1], matrix]
        end
      end

      module Keys
        def input_key(model, row)
          hash = row_hash(row)
          model.primary_key.map { |key| sized_text(field(hash, key)[1].to_s) }.join
        end

        def output_key(model, row)
          model.primary_key.map { |key| sized_text(row[column_index(model, key)].to_s) }.join
        end

        def sized_text(value) = "#{value.bytesize}:#{value}"

        def column_index(model, name)
          i = 0
          while i < model.columns.length
            return i if model.columns[i] == name

            i += 1
          end
          0
        end

        def row_hash(row)
          return row if row.is_a?(Hash)
          return row.attrs if row.is_a?(Model)

          raise ArgumentError, 'row'
        end
      end

      module Statements
        def insert_sql(model, part, mode, alias_rows)
          dialect = model.dialect
          binds = []
          table = Sql.quote(dialect, model.table_name)
          sql = "INSERT INTO #{table} (#{quoted_names(dialect, part[1])}) VALUES #{value_rows(dialect, part[2], binds)}"
          sql += " AS #{Sql.quote(dialect, 'kiln_new')}" if mode.update_conflicts && alias_rows
          sql += conflict_sql(model, part[1], mode, alias_rows)
          sql += " RETURNING #{returning_list(dialect, model)}" if mode.return_rows && dialect == :postgres
          [sql, binds]
        end

        def conflict_sql(model, names, mode, alias_rows)
          ignore = mode.skip_conflicts
          update = mode.update_conflicts
          return '' unless ignore || update

          dialect = model.dialect
          return mysql_update_sql(dialect, model, names, alias_rows) if update && dialect != :postgres
          return ' ON CONFLICT DO NOTHING' if ignore

          keys = model.primary_key
          " ON CONFLICT (#{quoted_names(dialect, keys)}) DO UPDATE SET #{excluded_sets(dialect, keys, names)}"
        end

        def mysql_update_sql(dialect, model, names, alias_rows)
          sets = update_columns(model.primary_key, names).map { |name| mysql_set(dialect, name, alias_rows) }
          " ON DUPLICATE KEY UPDATE #{sets.join(', ')}"
        end

        def returning_list(dialect, model) = quoted_names(dialect, model.columns)

        def copy_sql(model, names)
          dialect = model.dialect
          table = Sql.quote(dialect, model.table_name)
          "COPY #{table} (#{quoted_names(dialect, names)}) FROM STDIN"
        end

        private

        def quoted_names(dialect, names) = names.map { |name| Sql.quote(dialect, name) }.join(', ')

        def value_rows(dialect, matrix, binds)
          rows = []
          r = 0
          while r < matrix.length
            rows << "(#{value_list(dialect, matrix[r], binds)})"
            r += 1
          end
          rows.join(', ')
        end

        def value_list(dialect, values, binds)
          marks = []
          c = 0
          while c < values.length
            marks << value_mark(dialect, values[c], binds)
            c += 1
          end
          marks.join(', ')
        end

        def value_mark(dialect, value, binds)
          return 'CURRENT_TIMESTAMP' if value == :timestamp

          binds << value
          Sql.placeholder(dialect, binds)
        end

        def update_columns(keys, names)
          cols = names.reject { |name| keys.include?(name) }
          raise ArgumentError, 'update' if cols.empty?

          cols
        end

        def excluded_sets(dialect, keys, names)
          update_columns(keys, names).map do |name|
            quoted = Sql.quote(dialect, name)
            "#{quoted} = EXCLUDED.#{quoted}"
          end.join(', ')
        end

        def mysql_set(dialect, name, alias_rows)
          quoted = Sql.quote(dialect, name)
          alias_rows ? "#{quoted} = #{Sql.quote(dialect, 'kiln_new')}.#{quoted}" : "#{quoted} = VALUES(#{quoted})"
        end
      end

      module Copy
        COPY_NULL = '\\N'.b.freeze
        COPY_TAB = "\t".b.freeze
        COPY_EOL = "\n".b.freeze
        COPY_STAMP_SQL = 'SELECT CAST(CURRENT_TIMESTAMP AS text)'.freeze
        COPY_ESCAPES = Array.new(256).tap do |codes|
          codes[9] = 116
          codes[10] = 110
          codes[13] = 114
          codes[92] = 92
        end.freeze

        def copy_eligible?(dialect, mode, encoded_rows) = !copy_shape(dialect, mode, encoded_rows).negative?

        def copy_shape(dialect, mode, encoded_rows)
          return -1 unless dialect == :postgres
          return -1 if mode.skip_conflicts || mode.update_conflicts || mode.return_rows

          copy_rows_shape(encoded_rows)
        end

        def copy_rows_shape(encoded_rows)
          shape = 0
          r = 0
          while r < encoded_rows.length
            row = copy_row_shape(encoded_rows[r])
            return -1 if row.negative?

            shape = row if row.positive?
            r += 1
          end
          shape
        end

        def copy_stamp(conn) = conn.exec(COPY_STAMP_SQL, [])[0][0].to_s.b

        def copy_text(encoded_rows, stamp = nil)
          copy_chunk(encoded_rows, 0, encoded_rows.length * COPY_LIMIT, stamp)[0]
        end

        def copy_chunk(encoded_rows, offset, limit, stamp = nil)
          chunk = (+'').b
          i = offset
          while i < encoded_rows.length
            row = copy_row(encoded_rows[i], stamp)
            break if i > offset && chunk.bytesize + row.bytesize > limit

            chunk << row
            i += 1
          end
          [chunk, i - offset]
        end

        private

        def copy_row_shape(row)
          shape = 0
          c = 0
          while c < row.length
            value = row[c]
            return -1 if Codec.binary_text?(value)
            raise ArgumentError, 'bind String: NUL byte in text' if value.is_a?(String) && value.include?(Codec::NUL)

            shape = 1 if value == :timestamp
            c += 1
          end
          shape
        end

        def copy_row(values, stamp)
          out = (+'').b
          c = 0
          while c < values.length
            out << COPY_TAB if c.positive?
            out << copy_cell(values[c], stamp)
            c += 1
          end
          out << COPY_EOL
        end

        def copy_cell(value, stamp)
          return COPY_NULL if value.nil?
          return value.to_s if value.is_a?(Integer)
          return copy_escaped(value) if value.is_a?(String)
          return copy_stamp_text(stamp) if value == :timestamp

          copy_escaped(Codec.encode(:postgres, value)[0])
        end

        def copy_stamp_text(stamp)
          raise InvariantViolation, 'copy timestamp' if stamp.nil?

          stamp
        end

        def copy_escaped(text)
          raw = text.b
          return raw unless copy_special?(raw)

          escape_copy(raw)
        end

        def copy_special?(raw)
          raw.include?('\\') || raw.include?("\t") || raw.include?("\n") || raw.include?("\r")
        end

        def escape_copy(raw)
          out = (+'').b
          i = 0
          while i < raw.bytesize
            byte = raw.getbyte(i)
            escaped = COPY_ESCAPES[byte]
            escaped ? out << 92 << escaped : out << byte
            i += 1
          end
          out
        end
      end

      extend Checks
      extend Rows
      extend Keys
      extend Statements
      extend Copy
    end
  end
end
