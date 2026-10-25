module Kiln
  module DB
    ImportPart = Struct.new(:key, :columns, :rows, :originals)

    class ImportMode
      attr_reader :skip_conflicts, :update_conflicts, :return_rows, :settings

      def initialize(ignore, update, returning, settings = nil)
        @skip_conflicts = ignore
        @update_conflicts = update
        @return_rows = returning
        @settings = settings || ImportSettings.new(nil, nil, nil, nil, nil)
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
          Schema.prove_update_key(conn, @model) if @update && @returning
        end

        def write_part(conn, part, alias_rows)
          if part.columns.empty?
            part.rows.length.times { |index| write_page(conn, part, index, 1, alias_rows) }
            return
          end

          shape = copy_shape_for(conn, part.rows)
          return write_copy(conn, part, shape.positive? ? Import.copy_stamp(conn) : nil) unless shape.negative?

          step = Import.page_rows(part.columns.length)
          step = [step, @mode.settings.batch_size].min unless @mode.settings.batch_size.nil?
          offset = 0
          while offset < part.rows.length
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
          rows = part.rows
          offset = 0
          sql = Import.copy_sql(@model, part.columns)
          while offset < rows.length
            last = @mode.settings.batch_size.nil? ? rows.length : [rows.length, offset + @mode.settings.batch_size].min
            payload, count = Import.copy_chunk(rows, offset, Import::COPY_LIMIT, stamp, last)
            conn.copy_in(sql, payload, count)
            @num_inserts += 1
            @affected_rows += count
            mark_inserted(ImportPage.new(part.originals, offset, offset + count))
            offset += count
          end
        end

        def write_page(conn, part, offset, step, alias_rows)
          sql, binds = Import.insert_sql(@model, Import.page_part(part, offset, step), @mode, alias_rows)
          got = conn.exec(sql, binds)
          affected = conn.affected_rows
          check_warnings(conn)
          @num_inserts += 1
          @affected_rows += affected

          page = ImportPage.new(part.originals, offset, [offset + step, part.rows.length].min)
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

        def check_warnings(conn)
          return if @model.dialect == :postgres

          count = conn.warning_count
          return if count.zero?

          if @ignore
            warnings = conn.exec('SHOW WARNINGS', [])
            return if warnings.all? { |row| row[1].to_i == 1062 }
          end

          raise Error, 'import warnings'
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
            unknown = @update || (@ignore && @model.dialect != :postgres)
            @status[original] = unknown ? 'applied_unknown' : 'inserted' if @picks[original] >= 0
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
        ImportResult.committed(@status, collect_returned, @state).annotate(@model, [], @num_inserts, @affected_rows,
                                                                         @mode.settings.return_columns)
      end

      private

      def init_results(count)
        @picks = Array.new(count, -1)
        @status = Array.new(count, 'validation_invalid')
        @found_rows = []
        @orphaned = []
        @copy_table = 0
        @state = 'COMMITTED'
        @num_inserts = 0
        @affected_rows = 0
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
      attr_reader :state, :returned, :failed_instances, :num_inserts, :affected_rows

      def initialize(state, status, returned)
        @state = state
        @status = status
        @returned = returned
        @failed_instances = []
        @num_inserts = 0
        @affected_rows = 0
        @model = nil
        @return_columns = nil
      end

      def annotate(model, failed, inserts, affected, columns = nil)
        @model = model
        @failed_instances = failed
        @num_inserts = inserts
        @affected_rows = affected
        @return_columns = columns
        self
      end

      def ids
        return [] if @model.nil?

        indexes = @model.primary_key.map { |name| Import.column_index(@model, name) }
        @returned.map do |row|
          values = indexes.map { |index| row[index] }
          values.length == 1 ? values[0] : values
        end
      end

      def results
        return @returned if @return_columns.nil? || @model.nil?

        indexes = @return_columns.map { |name| Import.column_index(@model, name) }
        @returned.map do |row|
          values = indexes.map { |index| row[index] }
          values.length == 1 ? values[0] : values
        end
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
                       validate_uniqueness all_or_none timestamps raise_error ignore
                       batch_size track_validation_failures].freeze

      module Checks
        def call(model, rows, values, options, bang)
          if values.is_a?(Array)
            rows = ImportOptions.input(model, rows, values)
          else
            raise ArgumentError, 'options' unless options.nil?

            options = values
          end
          run(model, rows, options, bang)
        end

        def run(model, rows, options, bang)
          options = {} if options.nil?
          raise ArgumentError, 'rows' unless rows.is_a?(Array)
          raise ArgumentError, 'options' unless options.is_a?(Hash)

          options = options.merge(validate: true, raise_error: true) if bang
          check_options(options)
          mode = import_mode(model, rows, options)
          raise InvariantViolation, 'pipeline' if Scope.current&.pipelined?
          return ImportResult.empty if rows.empty?

          write_valid(model, rows, options, bang || options[:raise_error] == true, mode)
        end

        def check_options(options)
          raise ArgumentError, 'option' unless (options.keys - OPTION_KEYS).empty?
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
          rejected = failed.length.positive? && options[:all_or_none] == true
          failed_rows = failed.map do |index|
            record = original_row(rows[index])
            options[:track_validation_failures] == true ? [index, record] : record
          end
          if rejected || valid.empty?
            return ImportResult.rejected(rows.length).annotate(model, failed_rows, 0, 0)
          end

          parts = group_rows(model, valid, options[:timestamps] != false)
          validate_parts(model, parts, mode)
          result = Batch.new(model, rows, mode).write(parts)
          result.annotate(model, failed_rows, result.num_inserts, result.affected_rows, mode.settings.return_columns)
        end

        def import_mode(model, rows, options)
          ignore = ImportOptions.ignore?(options)
          update = ImportOptions.update?(options)
          settings = ImportOptions.settings(model, options)
          returning = !options[:returning].nil? && options[:returning] != false
          check_conflict(ignore, update)
          if update && model.dialect == :postgres && settings.target.empty? && settings.constraint.nil?
            raise ArgumentError, 'conflict target'
          end
          check_exact(options[:require_exact_status] == true, ignore, update, returning)
          if options[:require_exact_status] == true && ignore && model.dialect != :postgres
            raise UnsupportedExactStatus, 'mysql ignore status'
          end
          check_returning(model, rows) if returning
          if returning && update && (settings.target != model.primary_key || !settings.constraint.nil?)
            raise UnsupportedReturn, 'returning: primary key conflict target required'
          end
          ImportMode.new(ignore, update, returning, settings)
        end

        def check_conflict(ignore, update)
          raise ArgumentError, 'conflict' if ignore && update
        end

        def check_exact(exact, ignore, update, returning)
          return unless exact && (update || (ignore && !returning))

          raise UnsupportedExactStatus, 'status'
        end

        def check_returning(model, rows)
          raise UnsupportedReturn, 'returning' unless keys_ready?(model, rows)
          raise UnsupportedReturn, 'returning' if model.dialect != :postgres && model.primary_key.length != 1
        end

        def original_row(row) = row.is_a?(ImportRow) ? row.record : row

        def row_error(row, validate)
          record = original_row(row)
          validate && record.is_a?(Model) ? record.validate : nil
        end

        def validate_parts(model, parts, mode)
          return unless mode.update_conflicts

          parts.each { |part| conflict_sql(model, part.columns, mode, false) }
        end

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
          row.each_key do |key|
            raise ArgumentError, 'column' unless columns.include?(key.to_s)
          end
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
          stamp = ImportOptions::CREATE_STAMPS.include?(name) || ImportOptions::UPDATE_STAMPS.include?(name)
          return [true, :timestamp] if timestamps && stamp && (found.nil? || found[1].nil?)

          found
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
          if last >= 0 && groups[last].key == key
            groups[last].rows << values
            groups[last].originals << original_index
          else
            groups << ImportPart.new(key, names, [values], [original_index])
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
          last = part.rows.length if last > part.rows.length
          while i < last
            matrix << part.rows[i]
            i += 1
          end
          ImportPart.new(part.key, part.columns, matrix, nil)
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
          return row.attrs if row.is_a?(ImportRow)

          raise ArgumentError, 'row'
        end
      end

      module Statements
        def insert_sql(model, part, mode, alias_rows)
          dialect = model.dialect
          binds = []
          table = Sql.quote(dialect, model.table_name)
          verb = mode.skip_conflicts && dialect != :postgres ? 'INSERT IGNORE' : 'INSERT'
          values = if part.columns.empty? && dialect == :postgres
                     'DEFAULT VALUES'
                   else
                     "(#{quoted_names(dialect, part.columns)}) VALUES #{value_rows(dialect, part.rows, binds)}"
                   end
          sql = "#{verb} INTO #{table} #{values}"
          sql += " AS #{Sql.quote(dialect, 'kiln_new')}" if mode.update_conflicts && alias_rows
          sql += conflict_sql(model, part.columns, mode, alias_rows)
          sql += " RETURNING #{returning_list(dialect, model)}" if mode.return_rows && dialect == :postgres
          [sql, binds]
        end

        def conflict_sql(model, names, mode, alias_rows)
          ignore = mode.skip_conflicts
          update = mode.update_conflicts
          return '' unless ignore || update

          dialect = model.dialect
          return dialect == :postgres ? ' ON CONFLICT DO NOTHING' : '' if ignore

          columns = conflict_columns(model, names, mode)
          return mysql_update_sql(dialect, columns, alias_rows) if dialect != :postgres

          settings = mode.settings
          target = settings.constraint.nil? ? "(#{quoted_names(dialect, settings.target || model.primary_key)})" :
                     "ON CONSTRAINT #{Sql.quote(dialect, settings.constraint)}"
          " ON CONFLICT #{target} DO UPDATE SET #{excluded_sets(dialect, columns)}"
        end

        def mysql_update_sql(dialect, columns, alias_rows)
          sets = columns.map { |pair| mysql_set(dialect, pair[0], pair[1], alias_rows) }
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

        def conflict_columns(model, names, mode)
          available = mode.settings.timestamps ? names - ImportOptions::CREATE_STAMPS : names
          columns = mode.settings.updates || update_columns(model.primary_key, available).map { |name| [name, name] }
          raise ArgumentError, 'missing update source column' unless columns.all? { |pair| names.include?(pair[1]) }
          if mode.return_rows && columns.any? { |pair| model.primary_key.include?(pair[0]) }
            raise UnsupportedReturn, 'returning: updated primary key'
          end

          columns
        end

        def excluded_sets(dialect, columns)
          columns.map do |pair|
            "#{Sql.quote(dialect, pair[0])} = EXCLUDED.#{Sql.quote(dialect, pair[1])}"
          end.join(', ')
        end

        def mysql_set(dialect, name, source, alias_rows)
          quoted = Sql.quote(dialect, name)
          value = Sql.quote(dialect, source)
          alias_rows ? "#{quoted} = #{Sql.quote(dialect, 'kiln_new')}.#{value}" : "#{quoted} = VALUES(#{value})"
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

        def copy_chunk(encoded_rows, offset, limit, stamp = nil, last = nil)
          chunk = (+'').b
          i = offset
          last ||= encoded_rows.length
          while i < last
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
