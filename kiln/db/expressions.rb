module Kiln
  module DB
    class Star < Expr
      attr_reader :scope

      def initialize(scope = nil)
        super()
        @scope = scope
      end

      def name = '*'
    end

    class Aliased < Expr
      attr_reader :expr, :name

      def initialize(expr, name)
        super()
        @name = name.to_s
        raise ArgumentError, 'alias' unless Ident.ok?(@name)

        @expr = expr
      end
    end

    class Function < Expr
      attr_reader :name, :arguments, :distinct

      def initialize(name, arguments, distinct = false)
        super()
        @name = name.to_s
        raise ArgumentError, 'function' unless Ident.ok?(@name) && arguments.is_a?(Array)
        raise ArgumentError, 'distinct' unless distinct == true || distinct == false

        @arguments = arguments.map { |argument| Expressions.wrap(argument) }
        @distinct = distinct
      end
    end

    class Arithmetic < Expr
      attr_reader :op, :left, :right

      def initialize(op, left, right)
        super()
        @op = op
        @left = Expressions.wrap(left)
        @right = Expressions.wrap(right)
      end
    end

    class ScalarQuery < Expr
      attr_reader :query

      def initialize(query)
        super()
        @query = query
      end
    end

    class Match < Pred
      attr_reader :expr, :pattern, :escape, :case_sensitive, :negated

      def initialize(expr, pattern, escape, case_sensitive, negated)
        super()
        raise ArgumentError, 'matches' if pattern.nil?
        raise ArgumentError, 'escape' unless escape.nil? || (escape.is_a?(String) && escape.length == 1)

        @expr = expr
        @pattern = Expressions.wrap(pattern)
        @escape = escape
        @case_sensitive = case_sensitive
        @negated = negated
      end
    end

    module RangePredicate
      class << self
        def build(expr, range, negated)
          raise ArgumentError, 'range' unless range.is_a?(Range)

          low = range.begin
          high = range.end
          node = if low.nil? && high.nil?
                   Truth.new(true)
                 elsif low.nil?
                   range.exclude_end? ? expr.lt(high) : expr.lteq(high)
                 elsif high.nil?
                   expr.gteq(low)
                 elsif range.exclude_end?
                   expr.gteq(low).and(expr.lt(high))
                 else
                   Between.new(expr, Expressions.wrap(low), Expressions.wrap(high))
                 end
          negated ? node.not : node
        end
      end
    end

    class Truth < Pred
      attr_reader :value

      def initialize(value)
        super()
        @value = value
      end
    end

    CaseArm = Struct.new(:condition, :value)

    class CaseExpr < Expr
      attr_reader :operand, :arms, :default

      def initialize(operand = nil, arms = nil, default = nil)
        super()
        @operand = operand.nil? ? nil : Expressions.wrap(operand)
        @arms = arms || []
        @default = default
      end

      def when(condition, value = nil)
        cond = @operand.nil? ? condition : Expressions.wrap(condition)
        raise ArgumentError, 'case condition' if @operand.nil? && !cond.is_a?(Pred)

        node = CaseExpr.new(@operand, @arms + [CaseArm.new(cond, nil)], @default)
        value.nil? ? node : node.then(value)
      end

      def then(value)
        raise ArgumentError, 'case then' if @arms.empty? || !@arms[-1].value.nil?

        arms = @arms.dup
        arms[-1] = CaseArm.new(arms[-1].condition, Expressions.wrap(value))
        CaseExpr.new(@operand, arms, @default)
      end

      def else(value)
        CaseExpr.new(@operand, @arms, Expressions.wrap(value))
      end
    end

    class Window
      attr_reader :partitions, :orders

      def initialize(partitions = nil, orders = nil)
        @partitions = partitions || []
        @orders = orders || []
      end

      def partition(*expressions)
        raise ArgumentError, 'partition' unless expressions.all?(Expr)

        Window.new(@partitions + expressions, @orders)
      end

      def order(*expressions)
        sorts = expressions.map { |expr| expr.is_a?(Order) ? expr : expr.asc }
        Window.new(@partitions, @orders + sorts)
      end
    end

    class Windowed < Expr
      attr_reader :expr, :window

      def initialize(expr, window)
        super()
        raise ArgumentError, 'window' unless window.is_a?(Window)

        @expr = expr
        @window = window
      end
    end
  end
end
