module Kiln
  module DB
    module Sql
      PredicateScope = Struct.new(:dialect, :binds, :derived, :outer)

      module Predicates
        def where_sql(dialect, rel, binds, derived)
          return '' if rel.pred.nil?

          flag = derived || needs_full_rewrite?(dialect, rel)
          " WHERE #{pred_sql(dialect, rel.pred, binds, flag, flag ? rel : nil)}"
        end

        def pred_sql(dialect, node, binds, derived, outer)
          render_pred(node, PredicateScope.new(dialect, binds, derived, outer))
        end

        def cmp_op(operator)
          CMP_OPS[operator] || raise(ArgumentError, 'compare')
        end

        def bind_sql(dialect, value, binds)
          binds << value
          placeholder(dialect, binds)
        end

        private

        def render_pred(node, scope)
          case node
          when And, Or then junction_sql(node, scope)
          when Not then "(NOT #{render_pred(node.inner, scope)})"
          when ExistsPred then exists_pred(node, scope)
          when Cmp then cmp_sql(node, scope)
          when NullPred then null_sql(node, scope)
          when InPred then in_sql(node, scope)
          when Between then between_sql(node, scope)
          when Like then like_sql(node, scope)
          when Match then match_sql(node, scope)
          when Truth then node.value ? 'TRUE' : 'FALSE'
          else raise ArgumentError, 'predicate'
          end
        end

        def predicate_column(col, scope)
          expression_sql(col, scope)
        end

        def predicate_value(node, scope)
          expression_sql(node, scope)
        end

        def junction_sql(node, scope)
          word = node.is_a?(And) ? 'AND' : 'OR'
          left = render_pred(node.left, scope)
          "(#{left} #{word} #{render_pred(node.right, scope)})"
        end

        def exists_pred(node, scope)
          return exists_outer(node, scope) if scope.derived || !scope.outer.nil?

          prefix = node.missing ? 'NOT EXISTS (' : 'EXISTS ('
          "#{prefix}#{piece(scope.dialect, node.rel, :exists_sub, scope.binds)})"
        end

        def exists_outer(node, scope)
          raise Unsupported, 'full exists' if scope.outer.nil?

          inner = node.rel
          prefix = node.missing ? 'NOT EXISTS (' : 'EXISTS ('
          nested = PredicateScope.new(scope.dialect, scope.binds, false, scope.outer)
          where = inner.pred.nil? ? '' : " WHERE #{render_pred(inner.pred, nested)}"
          "#{prefix}SELECT 1 FROM #{from_sql(scope.dialect, inner, scope.binds)}#{where})"
        end

        def cmp_sql(node, scope)
          left = predicate_value(node.left, scope)
          "#{left}#{cmp_op(node.op)}#{predicate_value(node.right, scope)}"
        end

        def null_sql(node, scope)
          "#{predicate_column(node.col, scope)}#{node.wants_null ? ' IS NULL' : ' IS NOT NULL'}"
        end

        def in_sql(node, scope)
          return in_query_sql(node, scope) unless node.values.is_a?(Array)
          return node.negated ? 'TRUE' : 'FALSE' if node.values.empty?

          col = predicate_column(node.col, scope)
          marks = bind_marks(scope.dialect, node.values, scope.binds)
          "#{col}#{node.negated ? ' NOT IN (' : ' IN ('}#{marks})"
        end

        def like_sql(node, scope)
          col = predicate_column(node.col, scope)
          "#{col} LIKE #{predicate_value(node.pattern, scope)}"
        end

        def match_sql(node, scope)
          left = expression_sql(node.expr, scope)
          right = expression_sql(node.pattern, scope)
          word = scope.dialect == :postgres && !node.case_sensitive ? 'ILIKE' : 'LIKE'
          word = "NOT #{word}" if node.negated
          text = "#{left} #{word} #{right}"
          text += " ESCAPE #{bind_sql(scope.dialect, node.escape, scope.binds)}" unless node.escape.nil?
          text
        end

        def in_query_sql(node, scope)
          raise ArgumentError, 'subquery projection' unless picked_cols(node.values).length == 1

          left = predicate_column(node.col, scope)
          right = piece(scope.dialect, node.values, :rows, scope.binds)
          "#{left}#{node.negated ? ' NOT IN (' : ' IN ('}#{right})"
        end

        def between_sql(node, scope)
          col = predicate_column(node.col, scope)
          low = predicate_value(node.left, scope)
          "#{col} BETWEEN #{low} AND #{predicate_value(node.right, scope)}"
        end

        def bind_marks(dialect, values, binds)
          marks = []
          i = 0
          while i < values.length
            marks << compile_expression(dialect, Expressions.wrap(values[i]), binds)
            i += 1
          end
          marks.join(', ')
        end
      end
    end
  end
end
