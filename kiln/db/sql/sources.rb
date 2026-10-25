module Kiln
  module DB
    module Sql
      module Sources
        def from_sql(dialect, rel, binds)
          return full_derived(dialect, rel, binds) if needs_full_rewrite?(dialect, rel)

          unless rel.source.nil?
            if rel.source.is_a?(Table)
              return "#{table_source(dialect, rel.source, rel.source.table_alias, binds, rel.ctes)}#{joins_sql(dialect, rel, binds)}"
            end

            inner = piece(dialect, rel.source, :rows, binds)
            return "(#{inner}) #{quote(dialect, rel.model.table_alias)}#{joins_sql(dialect, rel, binds)}"
          end
          "#{table_ref(dialect, rel.model.table_name, rel.table_alias)}#{joins_sql(dialect, rel, binds)}"
        end

        def needs_full_rewrite?(dialect, rel)
          return false if dialect == :postgres

          i = 0
          while i < rel.join_nodes.length
            return true if rel.join_nodes[i].kind == :full

            i += 1
          end
          false
        end

        def join_sql(dialect, join, binds, ctes = nil)
          source = join.source.nil? ? table_ref(dialect, join.model.table_name, join.alias_name) :
                     table_source(dialect, join.source, join.alias_name, binds, ctes)
          text = "#{join_word(join.kind)} #{source}"
          return text if join.kind == :cross

          raise ArgumentError, 'on' if join.on_expr.nil? || join.on_expr.is_a?(String)

          "#{text} ON #{pred_sql(dialect, join.on_expr, binds, false, nil)}"
        end

        def join_word(kind)
          JOIN_WORDS[kind] || raise(ArgumentError, 'join')
        end

        def full_derived(dialect, rel, binds)
          join = full_join(rel)
          cols = all_cols(rel)
          left_from = full_left(dialect, rel, join, binds)
          right_from = full_right(dialect, rel, join, binds)
          left_sql = branch_select(dialect, cols, join.alias_name, false)
          right_sql = branch_select(dialect, cols, join.alias_name, true)
          "(#{left_sql} FROM #{left_from} UNION ALL #{right_sql} FROM #{right_from}) #{quote(dialect, 'kiln_full')}"
        end

        def branch_select(dialect, cols, right_alias, null_left)
          "SELECT #{cols.map { |col| branch_col(dialect, col, right_alias, null_left) }.join(', ')}"
        end

        private

        def table_source(dialect, model, alias_name, binds, ctes = nil)
          if !ctes.nil? && ctes.any? { |cte| cte.table.table_alias == model.table_alias }
            return table_ref(dialect, model.table_alias, alias_name)
          end
          unless model.query.nil?
            return "(#{piece(dialect, model.query, :rows, binds)}) #{quote(dialect, alias_name)}"
          end

          table_ref(dialect, model.table_name, alias_name)
        end

        def table_ref(dialect, table, alias_name) = "#{quote(dialect, table)} #{quote(dialect, alias_name)}"

        def joins_sql(dialect, rel, binds)
          rel.join_nodes.map { |join| " #{join_sql(dialect, join, binds, rel.ctes)}" }.join
        end

        def full_join(rel)
          raise Unsupported, 'full' if rel.join_nodes.length != 1

          join = rel.join_nodes[0]
          raise Unsupported, 'full' if join.kind != :full
          raise ArgumentError, 'on' if join.on_expr.nil? || join.on_expr.is_a?(String)

          join
        end

        def full_left(dialect, rel, join, binds)
          base = root_source(dialect, rel, binds)
          joined = join.source.nil? ? table_ref(dialect, join.model.table_name, join.alias_name) :
                     table_source(dialect, join.source, join.alias_name, binds, rel.ctes)
          "#{base} LEFT JOIN #{joined} ON #{pred_sql(dialect, join.on_expr, binds, false, nil)}"
        end

        def full_right(dialect, rel, join, binds)
          base = join.source.nil? ? table_ref(dialect, join.model.table_name, join.alias_name) :
                   table_source(dialect, join.source, join.alias_name, binds, rel.ctes)
          outer = root_source(dialect, rel, binds)
          on = pred_sql(dialect, join.on_expr, binds, false, nil)
          "#{base} WHERE NOT EXISTS (SELECT 1 FROM #{outer} WHERE #{on})"
        end

        def root_source(dialect, rel, binds)
          return table_source(dialect, rel.source, rel.table_alias, binds, rel.ctes) if rel.source.is_a?(Table)
          return "(#{piece(dialect, rel.source, :rows, binds)}) #{quote(dialect, rel.table_alias)}" unless rel.source.nil?

          table_ref(dialect, rel.model.table_name, rel.table_alias)
        end

        def plain_col(dialect, col) = "#{quote(dialect, col.scope)}.#{quote(dialect, col.name)}"

        def branch_col(dialect, col, right_alias, null_left)
          value = null_left && col.scope != right_alias ? 'NULL' : plain_col(dialect, col)
          "#{value} AS #{quote(dialect, "#{col.scope}__#{col.name}")}"
        end
      end
    end
  end
end
