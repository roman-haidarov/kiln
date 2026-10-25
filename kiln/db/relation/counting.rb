module Kiln
  module DB
    class Relation
      module Counting
        def exists?
          rows = run(:exists)
          rows.length.positive?
        end

        def first
          rows = limit(1).run(:rows)
          return nil if rows.empty?

          View::Row.new(pick_names, rows[0])
        end

        def first!
          row = first
          raise NotFound, @model.table_name if row.nil?

          row
        end

        def count
          rows = run(:count)
          return grouped(rows) if @groups.length.positive?
          return 0 if rows.empty?

          rows[0][0].to_i
        end

        def count_rows
          derive.put_groups([]).put_having(nil).put_orders([]).put_limit(nil).put_offset(nil).put_distinct(false).count
        end

        def count_root
          raise UnknownRootIdentity, 'root' if @joins.any? { |join| %i[full right].include?(join.kind) }
          raise UnknownRootIdentity, 'root' if @model.primary_key.length != 1

          rows = run(:root)
          return 0 if rows.empty?

          rows[0][0].to_i
        end

        def sum(col)
          agg_decimal('SUM', col)
        end

        def avg(col)
          agg_decimal('AVG', col)
        end

        def average(col)
          avg(col)
        end

        def sum_or_zero(col)
          value = sum(col)
          return ExactDecimal.parse('0') if value.nil?

          value
        end

        def min(col)
          agg_text('MIN', col)
        end

        def max(col)
          agg_text('MAX', col)
        end

        def agg_text(function, col)
          raise ArgumentError, 'aggregate' unless col.is_a?(Col)
          raise Unsupported, 'aggregate' if @groups.length.positive?

          binds = []
          sql = aggregate_sql(function, col, binds)
          rows = Scope.lease { |conn| conn.exec(sql, binds) }
          return nil if rows.empty? || rows[0][0].nil?

          rows[0][0]
        end

        def agg_decimal(function, col)
          value = agg_text(function, col)
          return nil if value.nil?
          return value if value.is_a?(ExactDecimal) || value.is_a?(Float)
          return ExactDecimal.from_i(value) if value.is_a?(Integer)

          ExactDecimal.parse(value.to_s)
        end

        private

        def aggregate_sql(function, col, binds)
          dialect = @model.dialect
          target = Sql.col_sql(dialect, col, false, nil)
          from = Sql.from_sql(dialect, self, binds)
          "SELECT #{function}(#{target}) FROM #{from}#{Sql.where_sql(dialect, self, binds, false)}"
        end

        def grouped(rows)
          width = @groups.length
          GroupedResult.new(rows.map { |row| [row.first(width), row[width].to_i] })
        end
      end
    end
  end
end
