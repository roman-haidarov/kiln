module Kiln
  module DB
    module Sql
      module Columns
        def aliased_cols(dialect, rel, binds = nil)
          derived = needs_full_rewrite?(dialect, rel)
          cols = picked_cols(rel)
          binds ||= []
          Array.new(cols.length) { |i| aliased_col(dialect, cols[i], derived, i, binds) }.join(', ')
        end

        def aliased_col(dialect, col, derived, index, binds = nil)
          expr = col.is_a?(Aliased) ? col.expr : col
          name = col.is_a?(Aliased) ? col.name : "c#{index}"
          "#{compile_expression(dialect, expr, binds || [], derived)} AS #{quote(dialect, name)}"
        end

        def select_sql(dialect, rel, mode, binds = nil)
          derived = needs_full_rewrite?(dialect, rel)
          binds ||= []
          cols = mode == :count ? "#{group_cols(dialect, rel, derived, binds)}, COUNT(*)" : list_cols(dialect, rel, derived, binds)
          rel.distinct_on && mode != :count ? "SELECT DISTINCT #{cols}" : "SELECT #{cols}"
        end

        def list_cols(dialect, rel, derived, binds = nil)
          binds ||= []
          picked_cols(rel).map { |col| compile_expression(dialect, col, binds, derived) }.join(', ')
        end

        def picked_cols(rel) = rel.picks || all_cols(rel)

        def all_cols(rel)
          cols = []
          if rel.source.is_a?(Table)
            rel.source.columns.each { |name| cols << Col.new(rel.table_alias, name) }
          else
            push_model_cols(cols, rel.model, rel.table_alias)
          end
          i = 0
          while i < rel.join_nodes.length
            join = rel.join_nodes[i]
            if join.source.nil?
              push_model_cols(cols, join.model, join.alias_name)
            else
              join.source.columns.each { |name| cols << Col.new(join.alias_name, name) }
            end
            i += 1
          end
          cols
        end

        def push_model_cols(cols, model, scope)
          i = 0
          names = model.columns
          while i < names.length
            cols << Col.new(scope, names[i])
            i += 1
          end
        end

        def group_cols(dialect, rel, derived, binds = nil)
          binds ||= []
          rel.groups.map do |col|
            col.is_a?(Aliased) ? quote(dialect, col.name) : compile_expression(dialect, col, binds, derived)
          end.join(', ')
        end

        def col_sql(dialect, col, derived, outer)
          raise ArgumentError, 'column' unless col.is_a?(Col)

          if derived || scope_outer?(outer, col.scope)
            "#{quote(dialect, 'kiln_full')}.#{quote(dialect, "#{col.scope}__#{col.name}")}"
          else
            "#{quote(dialect, col.scope)}.#{quote(dialect, col.name)}"
          end
        end

        def scope_outer?(rel, scope)
          return false if rel.nil?
          return true if rel.table_alias == scope

          i = 0
          joins = rel.join_nodes
          while i < joins.length
            return true if joins[i].alias_name == scope

            i += 1
          end
          false
        end
      end
    end
  end
end
