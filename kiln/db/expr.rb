module Kiln
  module DB
    module Ident
      NAME = /\A[A-Za-z_][A-Za-z0-9_]*\z/

      class << self
        def ok?(name) = name.is_a?(String) && NAME.match?(name)
      end
    end

    class Pred
      def and(other)
        raise ArgumentError, 'predicate' unless other.is_a?(Pred)

        And.new(self, other)
      end

      def or(other)
        raise ArgumentError, 'predicate' unless other.is_a?(Pred)

        Or.new(self, other)
      end

      def not
        Not.new(self)
      end
    end

    class And < Pred
      attr_reader :left, :right

      def initialize(left, right)
        super()
        @left = left
        @right = right
      end

      class << self
        def join(left, right)
          return right if left.nil?
          return left if right.nil?

          new(left, right)
        end
      end
    end

    class Or < Pred
      attr_reader :left, :right

      def initialize(left, right)
        super()
        @left = left
        @right = right
      end
    end

    class Not < Pred
      attr_reader :inner

      def initialize(inner)
        super()
        @inner = inner
      end
    end

    class Bound
      attr_reader :value

      def initialize(value)
        @value = value
      end
    end

    class Col
      attr_reader :scope, :name

      def initialize(scope, name)
        raise ArgumentError, 'identifier' unless Ident.ok?(scope) && Ident.ok?(name)

        @scope = scope
        @name = name
      end

      def eq(value)
        compare(:eq, value)
      end

      def ne(value)
        compare(:ne, value)
      end

      def gt(value)
        compare(:gt, value)
      end

      def gte(value)
        compare(:gte, value)
      end

      def lt(value)
        compare(:lt, value)
      end

      def lte(value)
        compare(:lte, value)
      end

      def in(values)
        InPred.new(self, values, false)
      end

      def not_in(values)
        InPred.new(self, values, true)
      end

      def between(left, right)
        raise ArgumentError, 'between' if left.nil? || right.nil?

        Between.new(self, Bound.new(left), Bound.new(right))
      end

      def like(pattern)
        raise ArgumentError, 'like' if pattern.nil?

        Like.new(self, Bound.new(pattern))
      end

      def null
        NullPred.new(self, true)
      end

      alias is_null null

      def not_null
        NullPred.new(self, false)
      end

      def asc
        Order.new(self, true)
      end

      def desc
        Order.new(self, false)
      end

      def set(value)
        raise ArgumentError, 'set(nil)' if value.nil?

        Assign.new(self, Bound.new(value))
      end

      def compare(operator, value)
        raise ArgumentError, 'eq(nil)' if value.nil? && %i[eq ne].include?(operator)

        right = value.is_a?(Col) ? value : Bound.new(value)
        Cmp.new(operator, self, right)
      end
    end

    class Cmp < Pred
      attr_reader :op, :left, :right

      def initialize(operator, left, right)
        super()
        @op = operator
        @left = left
        @right = right
      end
    end

    class NullPred < Pred
      attr_reader :col, :wants_null

      def initialize(col, wants_null)
        super()
        @col = col
        @wants_null = wants_null
      end
    end

    class InPred < Pred
      attr_reader :col, :values, :negated

      def initialize(col, values, negated)
        super()
        raise ArgumentError, 'in' unless values.is_a?(Array)
        raise ArgumentError, 'nil in list' if values.include?(nil)

        @col = col
        @values = values
        @negated = negated
      end
    end

    class Between < Pred
      attr_reader :col, :left, :right

      def initialize(col, left, right)
        super()
        @col = col
        @left = left
        @right = right
      end
    end

    class Like < Pred
      attr_reader :col, :pattern

      def initialize(col, pattern)
        super()
        @col = col
        @pattern = pattern
      end
    end

    class ExistsPred < Pred
      attr_reader :relation, :missing

      def rel
        @relation
      end

      def initialize(relation, missing)
        super()
        @relation = relation
        @missing = missing
      end
    end

    class Order
      attr_reader :col, :ascending

      def initialize(col, ascending)
        raise ArgumentError, 'order' unless col.is_a?(Col)

        @col = col
        @ascending = ascending
      end
    end

    class Assign
      attr_reader :col, :value

      def initialize(col, value)
        @col = col
        @value = value
      end
    end

    class Join
      attr_reader :kind, :model, :on_expr, :alias_name

      def initialize(kind, model, on_expr, alias_name)
        @kind = kind
        @model = model
        @on_expr = on_expr
        @alias_name = alias_name
      end
    end
  end
end
