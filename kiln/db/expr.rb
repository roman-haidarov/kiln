module Kiln
  module DB
    module Ident
      NAME = /\A[A-Za-z_][A-Za-z0-9_]*\z/

      class << self
        def ok?(name) = name.is_a?(String) && NAME.match?(name)
      end
    end

    class Expr
      def eq(value) = compare(:eq, value)
      def not_eq(value) = compare(:ne, value)
      def gt(value) = compare(:gt, value)
      def gteq(value) = compare(:gte, value)
      def lt(value) = compare(:lt, value)
      def lteq(value) = compare(:lte, value)

      alias ne not_eq
      alias gte gteq
      alias lte lteq

      def in(values)
        values.is_a?(Range) ? between(values) : InPred.new(self, values, false)
      end

      def not_in(values)
        values.is_a?(Range) ? not_between(values) : InPred.new(self, values, true)
      end

      def between(left, right = nil)
        return RangePredicate.build(self, left, false) if left.is_a?(Range)

        raise ArgumentError, 'between' if left.nil? || right.nil?

        Between.new(self, Expressions.wrap(left), Expressions.wrap(right))
      end

      def not_between(range) = RangePredicate.build(self, range, true)
      def matches(pattern, escape = nil, case_sensitive = false) = Match.new(self, pattern, escape, case_sensitive, false)
      def does_not_match(pattern, escape = nil, case_sensitive = false) = Match.new(self, pattern, escape, case_sensitive, true)
      def like(pattern)
        raise ArgumentError, 'like' if pattern.nil?

        Like.new(self, Expressions.wrap(pattern))
      end
      def null = NullPred.new(self, true)
      def not_null = NullPred.new(self, false)

      alias is_null null

      def asc = Order.new(self, true)
      def desc = Order.new(self, false)
      def as(name) = Aliased.new(self, name)
      def count(distinct = false) = Function.new('COUNT', [self], distinct)
      def sum = Function.new('SUM', [self])
      def average = Function.new('AVG', [self])
      def minimum = Function.new('MIN', [self])
      def maximum = Function.new('MAX', [self])
      def lower = Function.new('LOWER', [self])
      def upper = Function.new('UPPER', [self])
      def coalesce(*values) = Function.new('COALESCE', [self] + values)
      def +(other) = Arithmetic.new(:add, self, other)
      def -(other) = Arithmetic.new(:subtract, self, other)
      def *(other) = Arithmetic.new(:multiply, self, other)
      def /(other) = Arithmetic.new(:divide, self, other)
      def over(window = nil) = Windowed.new(self, window || Window.new)

      def set(value)
        raise ArgumentError, 'set(nil)' if value.nil?

        Assign.new(self, Expressions.wrap(value))
      end

      def compare(operator, value)
        return NullPred.new(self, operator == :eq) if value.nil? && %i[eq ne].include?(operator)

        Cmp.new(operator, self, Expressions.wrap(value))
      end
    end

    class Pred < Expr
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

    class Bound < Expr
      attr_reader :value

      def initialize(value)
        super()
        @value = value
      end
    end

    class Col < Expr
      attr_reader :scope, :name

      def initialize(scope, name)
        super()
        raise ArgumentError, 'identifier' unless Ident.ok?(scope) && Ident.ok?(name)

        @scope = scope
        @name = name
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
        raise ArgumentError, 'in' unless values.is_a?(Array) || values.is_a?(Relation) || values.is_a?(SetQuery)
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
        raise ArgumentError, 'order' unless col.is_a?(Expr)

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
      attr_reader :kind, :model, :on_expr, :alias_name, :source

      def initialize(kind, model, on_expr, alias_name, source = nil)
        @kind = kind
        @model = model
        @on_expr = on_expr
        @alias_name = alias_name
        @source = source
      end
    end

    module Expressions
      class << self
        def name(expr)
          return expr.name if expr.is_a?(Col) || expr.is_a?(Aliased) || expr.is_a?(Star)

          raise ArgumentError, 'expression needs an alias'
        end

        def wrap(value)
          return value if value.is_a?(Expr)
          return ScalarQuery.new(value) if value.is_a?(Relation) || value.is_a?(SetQuery)

          Bound.new(value)
        end

        def predicate(model, value)
          return value if value.is_a?(Pred)
          raise ArgumentError, 'predicate' unless value.is_a?(Hash)

          result = nil
          value.each do |key, item|
            col = model.table[key]
            node = if item.is_a?(Array)
                     array_predicate(col, item)
                   elsif item.is_a?(Relation) || item.is_a?(SetQuery)
                     col.in(item)
                   elsif item.is_a?(Range)
                     col.between(item)
                   else
                     col.eq(item)
                   end
            result = And.join(result, node)
          end
          result
        end

        def array_predicate(col, values)
          return col.in(values) unless values.include?(nil)

          present = values.reject(&:nil?)
          present.empty? ? col.eq(nil) : col.in(present).or(col.eq(nil))
        end
      end
    end
  end
end
