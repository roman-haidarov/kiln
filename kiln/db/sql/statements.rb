module Kiln
  module DB
    module Sql
      module Statements
        def emit(dialect, rel, mode)
          binds = []
          [piece(dialect, rel, mode, binds), binds]
        end

        def quote(dialect, name)
          raise ArgumentError, 'identifier' unless Ident.ok?(name)

          return "\"#{name}\"" if dialect == :postgres

          "`#{name}`"
        end

        def placeholder(dialect, binds)
          n = binds.length
          return '?' if dialect != :postgres

          "$#{n}"
        end

        def piece(dialect, rel, mode, binds)
          raise ArgumentError, 'dialect' unless %i[postgres mysql].include?(dialect)
          return compound_sql(dialect, rel, mode, binds) if rel.is_a?(SetQuery)

          prefix = with_sql(dialect, rel, binds)
          "#{prefix}#{statement_sql(dialect, rel, mode, binds)}"
        end

        def statement_sql(dialect, rel, mode, binds)
          if %i[exists exists_sub].include?(mode) && exists_shape?(rel)
            rows = rows_sql(dialect, rel, :rows, binds)
            return rows if mode == :exists_sub

            return "SELECT 1 FROM (#{rows}) #{quote(dialect, 'kiln_exists')} LIMIT 1"
          end
          return "SELECT 1 #{source_where(dialect, rel, binds)} LIMIT 1" if mode == :exists
          return "SELECT 1 #{source_where(dialect, rel, binds)}" if mode == :exists_sub
          return count_sql(dialect, rel, binds) if mode == :count && rel.groups.empty?
          return root_sql(dialect, rel, binds) if mode == :root

          rows_sql(dialect, rel, mode, binds)
        end

        def exists_shape?(rel)
          !rel.groups.empty? || !rel.having_node.nil? || !rel.picks.nil? || !rel.limit_n.nil? || !rel.offset_n.nil?
        end

        def with_sql(dialect, rel, binds)
          return '' if rel.ctes.empty?

          terms = rel.ctes.map do |cte|
            "#{quote(dialect, cte.table.table_alias)} AS (#{piece(dialect, cte.query, :rows, binds)})"
          end
          "WITH #{terms.join(', ')} "
        end

        def wrapped_count?(rel)
          rel.distinct_on || !rel.limit_n.nil? || !rel.offset_n.nil?
        end

        def count_wrapped(dialect, rel, binds)
          picked = rel.distinct_on ? "DISTINCT #{aliased_cols(dialect, rel, binds)}" : '1'
          from = source_where(dialect, rel, binds)
          tail = "#{order_sql(dialect, rel, binds)}#{limit_sql(dialect, rel)}"
          inner = "SELECT #{picked} #{from}#{tail}"
          "SELECT COUNT(*) FROM (#{inner}) #{quote(dialect, 'kiln_count')}"
        end

        private

        def source_where(dialect, rel, binds)
          from = from_sql(dialect, rel, binds)
          "FROM #{from}#{where_sql(dialect, rel, binds, false)}"
        end

        def count_sql(dialect, rel, binds)
          return count_wrapped(dialect, rel, binds) if wrapped_count?(rel)

          "SELECT COUNT(*) #{source_where(dialect, rel, binds)}"
        end

        def root_sql(dialect, rel, binds)
          keys = rel.model.primary_key
          raise UnknownRootIdentity, 'root' if keys.length != 1

          col = "#{quote(dialect, rel.table_alias)}.#{quote(dialect, keys[0])}"
          "SELECT COUNT(DISTINCT #{col}) #{source_where(dialect, rel, binds)}"
        end

        def rows_sql(dialect, rel, mode, binds)
          head = "#{select_sql(dialect, rel, mode, binds)} #{source_where(dialect, rel, binds)}"
          grouped = "#{group_sql(dialect, rel, binds)}#{having_sql(dialect, rel, binds)}"
          "#{head}#{grouped}#{order_sql(dialect, rel, binds)}#{limit_sql(dialect, rel)}"
        end
      end
    end
  end
end
