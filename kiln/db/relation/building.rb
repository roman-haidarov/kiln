module Kiln
  module DB
    class Relation
      module Building
        def where(expr)
          derive.put_pred(And.join(@pred, Expressions.predicate(predicate_source, expr)))
        end

        def order(*sorts)
          raise NonDeterministicQuery, 'order' if sorts.empty?
          sorts = sorts.flatten.map do |sort|
            value = sort.is_a?(Symbol) ? predicate_source.table[sort] : sort
            value.is_a?(Expr) ? value.asc : value
          end
          raise ArgumentError, 'order' unless sorts.all?(Order)

          derive.put_orders(@orders + sorts)
        end

        def limit(count)
          raise ArgumentError, 'limit' unless count.is_a?(Integer) && count >= 0

          derive.put_limit(count)
        end

        def offset(count)
          raise ArgumentError, 'offset' unless count.is_a?(Integer) && count >= 0

          derive.put_offset(count)
        end

        def select(*cols)
          derive.put_picks(projected(cols))
        end

        def columns(*cols)
          select(*cols)
        end

        def distinct(value = true)
          derive.put_distinct(value)
        end

        def group(*cols)
          cols = projected(cols)

          derive.put_groups(@groups + cols)
        end

        def having(expr)
          raise ArgumentError, 'having' if @groups.empty?

          derive.put_having(And.join(@having, Expressions.predicate(predicate_source, expr)))
        end

        def from(other)
          raise ArgumentError, 'from' unless other.is_a?(Relation) || other.is_a?(Table)

          derive.put_source(other)
        end

        def with(*queries)
          entries = queries.flatten.map do |query|
            if query.is_a?(Table) && !query.query.nil?
              CommonTable.new(query, query.query)
            elsif query.is_a?(CommonTable)
              query
            else
              raise ArgumentError, 'common table'
            end
          end
          all = @ctes + entries
          raise ArgumentError, 'duplicate common table' unless all.map { |cte| cte.table.table_alias }.uniq.length == all.length

          derive.put_ctes(all)
        end

        def preload(name, child = nil)
          assoc = @model.association(name)
          raise ArgumentError, 'preload' if assoc.nil?

          child = preload_child(assoc[2], child)
          check_preload(assoc, child)
          derive.add_preload([name, child, assoc])
        end

        def project(*cols)
          derive.put_picks((@picks || []) + projected(cols))
        end

        def take(count) = limit(count)
        def skip(count) = offset(count)

        def projected(cols)
          return cols if plain_exprs?(cols)

          list = cols.flatten.map { |col| col.is_a?(Symbol) ? predicate_source.table[col] : col }
          raise ArgumentError, 'select' if list.empty? || !list.all?(Expr)

          list
        end

        def add_join(kind, other, on_expr, alias_name)
          raise ArgumentError, 'join' unless other.is_a?(Class) || other.is_a?(Table)
          raise ArgumentError, 'on string' if on_expr.is_a?(String)
          raise ArgumentError, 'on' if kind != :cross && !on_expr.is_a?(Pred)

          model = other.is_a?(Table) ? other.model : other
          source = other.is_a?(Table) ? other : nil
          derive.put_joins(@joins + [Join.new(kind, model, on_expr, alias_name, source)])
        end

        def plain_exprs?(cols)
          return false if cols.empty?

          i = 0
          while i < cols.length
            return false unless cols[i].is_a?(Expr)

            i += 1
          end
          true
        end

        def pk_orders
          @model.primary_key.map { |key| Col.new(table_alias, key).asc }
        end

        def plain_child?(child)
          bare_filters?(child) && bare_shape?(child)
        end

        private

        def predicate_source
          @source.is_a?(Table) ? @source : @model
        end

        def preload_child(other, child)
          return other.all if child.nil?
          raise ArgumentError, 'preload' unless child.is_a?(Relation)
          raise ArgumentError, 'preload' if child.model != other

          child
        end

        def check_preload(assoc, child)
          raise Unsupported, 'preload' unless plain_child?(child)
          raise Unsupported, 'preload' if assoc[1] == :one && !child.limit_n.nil?
          raise Unsupported, 'preload' if !child.limit_n.nil? && child.orders.empty?
        end

        def bare_filters?(child)
          child.pred.nil? && child.having_node.nil? && child.join_nodes.empty? && child.groups.empty?
        end

        def bare_shape?(child)
          child.offset_n.nil? && child.source.nil? && child.picks.nil? && child.distinct_on != true
        end
      end
    end
  end
end
