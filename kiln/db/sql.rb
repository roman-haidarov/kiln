module Kiln
  module DB
    module Sql
      CMP_OPS = { eq: ' = ', ne: ' <> ', gt: ' > ', gte: ' >= ', lt: ' < ', lte: ' <= ' }.freeze
      JOIN_WORDS = { inner: 'INNER JOIN', left: 'LEFT JOIN', right: 'RIGHT JOIN', full: 'FULL OUTER JOIN',
                     cross: 'CROSS JOIN' }.freeze

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
          return "SELECT 1 #{source_where(dialect, rel, binds)} LIMIT 1" if mode == :exists
          return "SELECT 1 #{source_where(dialect, rel, binds)}" if mode == :exists_sub
          return count_sql(dialect, rel, binds) if mode == :count && rel.groups.empty?
          return root_sql(dialect, rel, binds) if mode == :root

          rows_sql(dialect, rel, mode, binds)
        end

        def wrapped_count?(rel)
          rel.distinct_on || !rel.limit_n.nil? || !rel.offset_n.nil?
        end

        def count_wrapped(dialect, rel, binds)
          picked = rel.distinct_on ? "DISTINCT #{aliased_cols(dialect, rel)}" : '1'
          tail = "#{order_sql(dialect, rel)}#{limit_sql(dialect, rel)}"
          inner = "SELECT #{picked} #{source_where(dialect, rel, binds)}#{tail}"
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

          col = "#{quote(dialect, rel.model.table_alias)}.#{quote(dialect, keys[0])}"
          "SELECT COUNT(DISTINCT #{col}) #{source_where(dialect, rel, binds)}"
        end

        def rows_sql(dialect, rel, mode, binds)
          head = "#{select_sql(dialect, rel, mode)} #{source_where(dialect, rel, binds)}"
          grouped = "#{group_sql(dialect, rel)}#{having_sql(dialect, rel, binds)}"
          "#{head}#{grouped}#{order_sql(dialect, rel)}#{limit_sql(dialect, rel)}"
        end
      end

      module Columns
        def aliased_cols(dialect, rel)
          derived = needs_full_rewrite?(dialect, rel)
          cols = picked_cols(rel)
          Array.new(cols.length) { |i| aliased_col(dialect, cols[i], derived, i) }.join(', ')
        end

        def aliased_col(dialect, col, derived, index)
          "#{col_sql(dialect, col, derived, nil)} AS #{quote(dialect, "c#{index}")}"
        end

        def select_sql(dialect, rel, mode)
          derived = needs_full_rewrite?(dialect, rel)
          cols = mode == :count ? "#{group_cols(dialect, rel, derived)}, COUNT(*)" : list_cols(dialect, rel, derived)
          rel.distinct_on && mode != :count ? "SELECT DISTINCT #{cols}" : "SELECT #{cols}"
        end

        def list_cols(dialect, rel, derived)
          picked_cols(rel).map { |col| col_sql(dialect, col, derived, nil) }.join(', ')
        end

        def picked_cols(rel) = rel.picks || all_cols(rel)

        def all_cols(rel)
          cols = []
          push_model_cols(cols, rel.model, rel.model.table_alias)
          i = 0
          while i < rel.join_nodes.length
            join = rel.join_nodes[i]
            push_model_cols(cols, join.model, join.alias_name)
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

        def group_cols(dialect, rel, derived)
          rel.groups.map { |col| col_sql(dialect, col, derived, nil) }.join(', ')
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
          return true if rel.model.table_alias == scope

          i = 0
          joins = rel.join_nodes
          while i < joins.length
            return true if joins[i].alias_name == scope

            i += 1
          end
          false
        end
      end

      module Sources
        def from_sql(dialect, rel, binds)
          unless rel.source.nil?
            inner = piece(dialect, rel.source, :rows, binds)
            return "(#{inner}) #{quote(dialect, rel.model.table_alias)}"
          end
          return full_derived(dialect, rel, binds) if needs_full_rewrite?(dialect, rel)

          "#{table_ref(dialect, rel.model.table_name, rel.model.table_alias)}#{joins_sql(dialect, rel, binds)}"
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

        def join_sql(dialect, join, binds)
          text = "#{join_word(join.kind)} #{table_ref(dialect, join.model.table_name, join.alias_name)}"
          return text if join.kind == :cross

          raise ArgumentError, 'on' if join.on_expr.nil? || join.on_expr.is_a?(String)

          "#{text} ON #{pred_sql(dialect, join.on_expr, binds, false, nil)}"
        end

        def join_word(kind)
          JOIN_WORDS[kind] || raise(ArgumentError, 'join')
        end

        def full_derived(dialect, rel, binds)
          join = full_join(rel)
          cols = picked_cols(rel)
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

        def table_ref(dialect, table, alias_name) = "#{quote(dialect, table)} #{quote(dialect, alias_name)}"

        def joins_sql(dialect, rel, binds)
          rel.join_nodes.map { |join| " #{join_sql(dialect, join, binds)}" }.join
        end

        def full_join(rel)
          raise Unsupported, 'full' if rel.join_nodes.length != 1

          join = rel.join_nodes[0]
          raise Unsupported, 'full' if join.kind != :full
          raise ArgumentError, 'on' if join.on_expr.nil? || join.on_expr.is_a?(String)

          join
        end

        def full_left(dialect, rel, join, binds)
          model = rel.model
          base = table_ref(dialect, model.table_name, model.table_alias)
          joined = table_ref(dialect, join.model.table_name, join.alias_name)
          "#{base} LEFT JOIN #{joined} ON #{pred_sql(dialect, join.on_expr, binds, false, nil)}"
        end

        def full_right(dialect, rel, join, binds)
          model = rel.model
          base = table_ref(dialect, join.model.table_name, join.alias_name)
          outer = table_ref(dialect, model.table_name, model.table_alias)
          on = pred_sql(dialect, join.on_expr, binds, false, nil)
          "#{base} WHERE NOT EXISTS (SELECT 1 FROM #{outer} WHERE #{on})"
        end

        def plain_col(dialect, col) = "#{quote(dialect, col.scope)}.#{quote(dialect, col.name)}"

        def branch_col(dialect, col, right_alias, null_left)
          value = null_left && col.scope != right_alias ? 'NULL' : plain_col(dialect, col)
          "#{value} AS #{quote(dialect, "#{col.scope}__#{col.name}")}"
        end
      end

      module Predicates
        def where_sql(dialect, rel, binds, derived)
          return '' if rel.pred.nil?

          flag = derived || needs_full_rewrite?(dialect, rel)
          " WHERE #{pred_sql(dialect, rel.pred, binds, flag, flag ? rel : nil)}"
        end

        def pred_sql(dialect, node, binds, derived, outer)
          case node
          when And, Or then junction_sql(dialect, node, binds, derived, outer)
          when Not then "(NOT #{pred_sql(dialect, node.inner, binds, derived, outer)})"
          when ExistsPred then exists_pred(dialect, node, binds, derived, outer)
          else leaf_sql(dialect, node, binds, derived, outer)
          end
        end

        def exists_outer(dialect, node, binds, outer)
          raise Unsupported, 'full exists' if outer.nil?

          inner = node.rel
          text = node.missing ? 'NOT EXISTS (' : 'EXISTS ('
          where = ''
          where = " WHERE #{pred_sql(dialect, inner.pred, binds, false, outer)}" unless inner.pred.nil?
          "#{text}SELECT 1 FROM #{from_sql(dialect, inner, binds)}#{where})"
        end

        def cmp_op(operator)
          CMP_OPS[operator] || raise(ArgumentError, 'compare')
        end

        def value_sql(dialect, node, binds, derived, outer)
          return col_sql(dialect, node, derived, outer) if node.is_a?(Col)
          return bind_sql(dialect, node.value, binds) if node.is_a?(Bound)

          raise ArgumentError, 'value'
        end

        def bind_sql(dialect, value, binds)
          binds << value
          placeholder(dialect, binds)
        end

        def in_sql(dialect, node, binds, derived, outer)
          return node.negated ? 'TRUE' : 'FALSE' if node.values.empty?

          col = col_sql(dialect, node.col, derived, outer)
          "#{col}#{node.negated ? ' NOT IN (' : ' IN ('}#{bind_marks(dialect, node.values, binds)})"
        end

        def exists_sql(dialect, node, binds)
          text = node.missing ? 'NOT EXISTS (' : 'EXISTS ('
          "#{text}#{piece(dialect, node.rel, :exists_sub, binds)})"
        end

        private

        def junction_sql(dialect, node, binds, derived, outer)
          word = node.is_a?(And) ? 'AND' : 'OR'
          left = pred_sql(dialect, node.left, binds, derived, outer)
          "(#{left} #{word} #{pred_sql(dialect, node.right, binds, derived, outer)})"
        end

        def exists_pred(dialect, node, binds, derived, outer)
          return exists_outer(dialect, node, binds, outer) if derived || !outer.nil?

          exists_sql(dialect, node, binds)
        end

        def leaf_sql(dialect, node, binds, derived, outer)
          case node
          when Cmp then cmp_sql(dialect, node, binds, derived, outer)
          when NullPred then null_sql(dialect, node, derived, outer)
          when InPred then in_sql(dialect, node, binds, derived, outer)
          when Between then between_sql(dialect, node, binds, derived, outer)
          when Like then like_sql(dialect, node, binds, derived, outer)
          else raise ArgumentError, 'predicate'
          end
        end

        def cmp_sql(dialect, node, binds, derived, outer)
          left = value_sql(dialect, node.left, binds, derived, outer)
          "#{left}#{cmp_op(node.op)}#{value_sql(dialect, node.right, binds, derived, outer)}"
        end

        def null_sql(dialect, node, derived, outer)
          "#{col_sql(dialect, node.col, derived, outer)}#{node.wants_null ? ' IS NULL' : ' IS NOT NULL'}"
        end

        def like_sql(dialect, node, binds, derived, outer)
          col = col_sql(dialect, node.col, derived, outer)
          "#{col} LIKE #{value_sql(dialect, node.pattern, binds, derived, outer)}"
        end

        def between_sql(dialect, node, binds, derived, outer)
          col = col_sql(dialect, node.col, derived, outer)
          low = value_sql(dialect, node.left, binds, derived, outer)
          "#{col} BETWEEN #{low} AND #{value_sql(dialect, node.right, binds, derived, outer)}"
        end

        def bind_marks(dialect, values, binds)
          marks = []
          i = 0
          while i < values.length
            marks << bind_sql(dialect, values[i], binds)
            i += 1
          end
          marks.join(', ')
        end
      end

      module Clauses
        def group_sql(dialect, rel)
          return '' if rel.groups.empty?

          " GROUP BY #{group_cols(dialect, rel, needs_full_rewrite?(dialect, rel))}"
        end

        def having_sql(dialect, rel, binds)
          return '' if rel.having_node.nil?

          flag = needs_full_rewrite?(dialect, rel)
          " HAVING #{pred_sql(dialect, rel.having_node, binds, flag, flag ? rel : nil)}"
        end

        def order_sql(dialect, rel)
          return '' if rel.orders.empty?

          derived = needs_full_rewrite?(dialect, rel)
          " ORDER BY #{rel.orders.map { |order| order_term(dialect, order, derived) }.join(', ')}"
        end

        def limit_sql(dialect, rel)
          return '' if rel.limit_n.nil? && rel.offset_n.nil?

          text = ''
          if !rel.limit_n.nil?
            text += " LIMIT #{rel.limit_n}"
          elsif dialect != :postgres
            text += ' LIMIT 18446744073709551615'
          end
          text += " OFFSET #{rel.offset_n}" unless rel.offset_n.nil?
          text
        end

        private

        def order_term(dialect, order, derived)
          raise ArgumentError, 'order' unless order.is_a?(Order)

          "#{col_sql(dialect, order.col, derived, nil)}#{order.ascending ? ' ASC' : ' DESC'}"
        end
      end

      extend Statements
      extend Columns
      extend Sources
      extend Predicates
      extend Clauses
    end
  end
end
