module Kiln
  module DB
    class Relation
      module Joining
        def inner_join(other, on:)
          add_join(:inner, other, on, other.table_alias)
        end

        def joins(other, on: nil)
          return inner_join(other, on: on) unless on.nil?

          nodes = other.is_a?(Relation) ? other.join_sources : other
          nodes = [nodes] if nodes.is_a?(Join)
          raise ArgumentError, 'joins' unless nodes.is_a?(Array) && nodes.all?(Join)

          derive.put_joins(@joins + nodes)
        end

        def join(other, kind = Arel::Nodes::InnerJoin)
          raise ArgumentError, 'join' unless other.is_a?(Class) || other.is_a?(Table)

          type = join_kind(kind)
          model = other.is_a?(Table) ? other.model : other
          source = other.is_a?(Table) ? other : nil
          derive.put_joins(@joins + [Join.new(type, model, nil, other.table_alias, source)])
        end

        def outer_join(other) = join(other, Arel::Nodes::OuterJoin)
        def join_sources = @joins.dup

        def on(*expressions)
          raise ArgumentError, 'on' if @joins.empty? || @joins[-1].kind == :cross

          node = nil
          expressions.flatten.each { |expr| node = And.join(node, Expressions.predicate(predicate_source, expr)) }
          raise ArgumentError, 'on' if node.nil?

          last = @joins[-1]
          list = @joins.dup
          list[-1] = Join.new(last.kind, last.model, And.join(last.on_expr, node), last.alias_name, last.source)
          derive.put_joins(list)
        end

        def inner_joins(other, on:)
          inner_join(other, on: on)
        end

        def left_join(other, on:)
          add_join(:left, other, on, other.table_alias)
        end

        def left_joins(other, on:)
          left_join(other, on: on)
        end

        def left_outer_joins(other, on:)
          left_join(other, on: on)
        end

        def right_join(other, on:)
          add_join(:right, other, on, other.table_alias)
        end

        def full_join(other, on:)
          add_join(:full, other, on, other.table_alias)
        end

        def cross_join(other)
          add_join(:cross, other, nil, other.table_alias)
        end

        def join_as(other, alias_name, on:)
          raise ArgumentError, 'identifier' unless Ident.ok?(alias_name)

          add_join(:inner, other, on, alias_name)
        end

        def where_exists(other)
          raise ArgumentError, 'exists' unless other.is_a?(Relation)

          where(ExistsPred.new(other, false))
        end

        def where_missing(other)
          raise ArgumentError, 'exists' unless other.is_a?(Relation)

          where(ExistsPred.new(other, true))
        end

        def through(middle, target, first_on, second_on)
          inner_join(middle, on: first_on).inner_join(target, on: second_on)
        end

        private

        def join_kind(kind)
          return :inner if kind == Arel::Nodes::InnerJoin
          return :left if kind == Arel::Nodes::OuterJoin
          return :right if kind == Arel::Nodes::RightOuterJoin
          return :full if kind == Arel::Nodes::FullOuterJoin
          return :cross if kind == Arel::Nodes::CrossJoin

          raise ArgumentError, 'join kind'
        end
      end
    end
  end
end
