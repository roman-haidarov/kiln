module Kiln
  module DB
    class Relation
      module Reading
        def compile(mode = :rows)
          Sql.emit(@model.dialect, self, mode)
        end

        def to_sql
          compile(:rows)[0]
        end

        def to_binds
          compile(:rows)[1]
        end

        def to_a
          run(:rows)
        end

        def models
          raise Unsupported, 'models' if @joins.length.positive? || !@picks.nil? || !@source.nil?

          parents = row_models(run(:rows), pick_names)
          attach_preloads(parents) if @preloads.length.positive?
          parents
        end

        def each
          rows = to_a
          names = pick_names
          i = 0
          while i < rows.length
            yield View::Row.new(names, rows[i])
            i += 1
          end
          nil
        end

        def collect
          rows = to_a
          names = pick_names
          out = []
          i = 0
          while i < rows.length
            out << yield(View::Row.new(names, rows[i]))
            i += 1
          end
          out
        end

        def map(&)
          collect(&)
        end

        def stream
          names = pick_names
          sql, binds = compile(:rows)
          Scope.lease do |conn|
            conn.each_row(sql, binds) { |row| yield View::Row.new(names, row) }
          end
          nil
        end

        def pluck(*cols)
          rel = select(*cols)
          return rel.run(:rows) unless cols.length == 1

          compiled = rel.compile(:rows)
          Scope.lease { |conn| conn.pluck_column(compiled[0], compiled[1]) }
        end

        def pick(col)
          rel = self
          rel = rel.order(*pk_orders) if rel.orders.empty?
          raise NonDeterministicQuery, 'pick' if rel.orders.empty?

          rows = rel.limit(1).select(col).run(:rows)
          return nil if rows.empty?

          rows[0][0]
        end

        def ids
          keys = @model.primary_key
          raise NonDeterministicQuery, 'ids' if keys.empty?

          select(*keys.map { |key| Col.new(table_alias, key) }).run(:rows)
        end

        def run(mode)
          compiled = compile(mode)
          Scope.lease { |conn| conn.exec(compiled[0], compiled[1]) }
        end

        def pick_names
          (@picks || Sql.all_cols(self)).map { |expr| Expressions.name(expr) }
        end

        private

        def row_models(raw, names)
          parents = []
          i = 0
          while i < raw.length
            parents << @model.restore(names_hash(names, raw[i]))
            i += 1
          end
          parents
        end

        def names_hash(names, row)
          attrs = {}
          c = 0
          while c < names.length
            attrs[names[c]] = row[c]
            c += 1
          end
          attrs
        end
      end
    end
  end
end
