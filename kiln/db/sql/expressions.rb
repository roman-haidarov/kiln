module Kiln
  module DB
    module Sql
      module ExpressionsSql
        ARITHMETIC = { add: '+', subtract: '-', multiply: '*', divide: '/' }.freeze

        def expression_sql(node, scope)
          case node
          when Col then col_sql(scope.dialect, node, scope.derived, scope.outer)
          when Bound then bind_sql(scope.dialect, node.value, scope.binds)
          when Pred then render_pred(node, scope)
          when Aliased then "#{expression_sql(node.expr, scope)} AS #{quote(scope.dialect, node.name)}"
          when Function then function_sql(node, scope)
          when Arithmetic then arithmetic_sql(node, scope)
          when Star then node.scope.nil? ? '*' : "#{quote(scope.dialect, node.scope)}.*"
          when ScalarQuery then "(#{piece(scope.dialect, node.query, :rows, scope.binds)})"
          when CaseExpr then case_sql(node, scope)
          when Windowed then "#{expression_sql(node.expr, scope)} OVER (#{window_sql(node.window, scope)})"
          else raise ArgumentError, 'expression'
          end
        end

        def compile_expression(dialect, node, binds, derived = false, outer = nil)
          expression_sql(node, PredicateScope.new(dialect, binds, derived, outer))
        end

        def compound_sql(dialect, query, mode, binds)
          left = piece(dialect, query.left, :rows, binds)
          right = piece(dialect, query.right, :rows, binds)
          word = { union: 'UNION', all: 'UNION ALL', intersect: 'INTERSECT', except: 'EXCEPT' }[query.kind]
          text = "(#{left}) #{word} (#{right})"
          return text if mode == :rows
          return "SELECT COUNT(*) FROM (#{text}) #{quote(dialect, 'kiln_set')}" if mode == :count
          return "SELECT 1 FROM (#{text}) #{quote(dialect, 'kiln_set')} LIMIT 1" if %i[exists exists_sub].include?(mode)

          raise Unsupported, 'set query mode'
        end

        private

        def function_sql(node, scope)
          arguments = node.arguments.map { |argument| expression_sql(argument, scope) }.join(', ')
          "#{node.name}(#{node.distinct ? 'DISTINCT ' : ''}#{arguments})"
        end

        def arithmetic_sql(node, scope)
          word = ARITHMETIC[node.op] || raise(ArgumentError, 'arithmetic')
          left = expression_sql(node.left, scope)
          "(#{left} #{word} #{expression_sql(node.right, scope)})"
        end

        def case_sql(node, scope)
          raise ArgumentError, 'case' if node.arms.empty?

          text = node.operand.nil? ? 'CASE' : "CASE #{expression_sql(node.operand, scope)}"
          node.arms.each do |arm|
            raise ArgumentError, 'case then' if arm.value.nil?

            text += " WHEN #{expression_sql(arm.condition, scope)} THEN #{expression_sql(arm.value, scope)}"
          end
          text += " ELSE #{expression_sql(node.default, scope)}" unless node.default.nil?
          "#{text} END"
        end

        def window_sql(window, scope)
          parts = []
          unless window.partitions.empty?
            parts << "PARTITION BY #{window.partitions.map { |expr| expression_sql(expr, scope) }.join(', ')}"
          end
          unless window.orders.empty?
            parts << "ORDER BY #{window.orders.map { |order| order_expression(order, scope) }.join(', ')}"
          end
          parts.join(' ')
        end

        def order_expression(order, scope)
          if order.col.is_a?(Aliased)
            return "#{quote(scope.dialect, order.col.name)}#{order.ascending ? ' ASC' : ' DESC'}"
          end

          "#{expression_sql(order.col, scope)}#{order.ascending ? ' ASC' : ' DESC'}"
        end
      end
    end
  end
end
