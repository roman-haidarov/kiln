module Kiln
  module DB
    class Table
      attr_reader :model, :query

      def initialize(model, alias_name = nil, query = nil)
        @model = model
        @alias_name = alias_name.nil? ? model.table_alias : alias_name.to_s
        raise ArgumentError, 'alias' unless Ident.ok?(@alias_name)

        @query = query
      end

      def [](name)
        return Star.new(table_alias) if name == :* || name == '*'

        text = name.to_s
        raise ArgumentError, 'column' unless column?(text)

        Col.new(table_alias, text)
      end

      def alias(name) = Table.new(@model, name, @query)
      def table = self
      def table_name = @model.table_name
      def table_alias = @alias_name
      def dialect = @model.dialect
      def primary_key = @model.primary_key
      def association(name) = @model.association(name)
      def restore(attrs) = @model.restore(attrs)
      def name = table_name

      def columns
        return @model.columns if @query.nil? || @query.picks.nil?

        @query.picks.map { |expr| Expressions.name(expr) }
      end

      def column?(name) = columns.include?(name)
      def all = Relation.blank(@model).from(self)
      def project(*expressions) = all.project(*expressions)
      def where(expr) = all.where(expr)
      def join(other, kind = Arel::Nodes::InnerJoin) = all.join(other, kind)
      def outer_join(other) = join(other, Arel::Nodes::OuterJoin)
      def group(*expressions) = all.group(*expressions)
      def order(*expressions) = all.order(*expressions)
    end

    class SetQuery
      include QueryComposition

      attr_reader :kind, :left, :right

      def initialize(kind, left, right)
        raise ArgumentError, 'set query' unless %i[union all intersect except].include?(kind)
        raise ArgumentError, 'query' unless right.is_a?(Relation) || right.is_a?(SetQuery)
        raise ArgumentError, 'dialect' unless left.model.dialect == right.model.dialect
        raise ArgumentError, 'projection width' unless Sql.picked_cols(left).length == Sql.picked_cols(right).length

        @kind = kind
        @left = left
        @right = right
      end

      def model = @left.model
      def picks = Sql.picked_cols(@left)
      def compile(mode = :rows) = Sql.emit(model.dialect, self, mode)
      def to_sql = compile[0]
      def to_binds = compile[1]

      def to_a
        sql, binds = compile
        Scope.lease { |conn| conn.exec(sql, binds) }
      end
    end

    class CommonTable
      attr_reader :table, :query

      def initialize(table, query)
        raise ArgumentError, 'common table' unless table.is_a?(Table) && (query.is_a?(Relation) || query.is_a?(SetQuery))

        @table = table
        @query = query
      end
    end

    module Arel
      class Table < DB::Table; end

      class SelectManager < Relation
        def initialize(table)
          raise ArgumentError, 'table' unless table.is_a?(DB::Table)

          super(table.model)
          @source = table
        end
      end

      module Nodes
        class On
          attr_reader :expr

          def initialize(expr)
            raise ArgumentError, 'on' unless expr.is_a?(Pred)

            @expr = expr
          end
        end

        class JoinNode < Join
          def initialize(kind, table, expr)
            raise ArgumentError, 'table' unless table.is_a?(DB::Table)

            expr = expr.expr if expr.is_a?(On)
            super(kind, table.model, expr, table.table_alias, table)
          end
        end

        class InnerJoin < JoinNode
          def initialize(table, expr = nil) = super(:inner, table, expr)
        end

        class OuterJoin < JoinNode
          def initialize(table, expr = nil) = super(:left, table, expr)
        end

        class RightOuterJoin < JoinNode
          def initialize(table, expr = nil) = super(:right, table, expr)
        end

        class FullOuterJoin < JoinNode
          def initialize(table, expr = nil) = super(:full, table, expr)
        end

        class CrossJoin < JoinNode
          def initialize(table, expr = nil) = super(:cross, table, expr)
        end
        class NamedFunction < Function; end
        class Case < CaseExpr; end
        class Window < DB::Window; end
        class As < CommonTable; end
      end

      class << self
        def star = Star.new
        def build_quoted(value) = Expressions.wrap(value)
      end
    end
  end
end
