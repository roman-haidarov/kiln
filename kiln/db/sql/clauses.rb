module Kiln
  module DB
    module Sql
      module Clauses
        def group_sql(dialect, rel, binds = nil)
          return '' if rel.groups.empty?

          " GROUP BY #{group_cols(dialect, rel, needs_full_rewrite?(dialect, rel), binds)}"
        end

        def having_sql(dialect, rel, binds)
          return '' if rel.having_node.nil?

          flag = needs_full_rewrite?(dialect, rel)
          " HAVING #{pred_sql(dialect, rel.having_node, binds, flag, flag ? rel : nil)}"
        end

        def order_sql(dialect, rel, binds = nil)
          return '' if rel.orders.empty?

          derived = needs_full_rewrite?(dialect, rel)
          binds ||= []
          " ORDER BY #{rel.orders.map { |order| order_term(dialect, order, derived, binds) }.join(', ')}"
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

        def order_term(dialect, order, derived, binds)
          raise ArgumentError, 'order' unless order.is_a?(Order)

          order_expression(order, PredicateScope.new(dialect, binds, derived, nil))
        end
      end
    end
  end
end
