module Kiln
  module DB
    class Relation
      module State
        protected

        def put_joins(value)
          @joins = value
          self
        end

        def put_pred(value)
          @pred = value
          self
        end

        def put_groups(value)
          @groups = value
          self
        end

        def put_having(value)
          @having = value
          self
        end

        def put_orders(value)
          @orders = value
          self
        end

        def put_limit(value)
          @limit_n = value
          self
        end

        def put_offset(value)
          @offset_n = value
          self
        end

        def put_picks(value)
          @picks = value
          self
        end

        def put_distinct(value)
          @distinct_on = value
          self
        end

        def put_source(value)
          @source = value
          self
        end

        def preload_list = @preloads
      end

      module Building
        def where(expr)
          raise ArgumentError, 'predicate' if expr.is_a?(String) || !expr.is_a?(Pred)

          derive.put_pred(And.join(@pred, expr))
        end

        def order(*sorts)
          raise NonDeterministicQuery, 'order' if sorts.empty?
          raise ArgumentError, 'order' unless sorts.all?(Order)

          derive.put_orders(@orders + sorts)
        end

        def limit(count)
          raise ArgumentError, 'limit' unless count.is_a?(Integer) && count >= 0

          derive.put_limit(count)
        end

        def offset(count)
          raise ArgumentError, 'offset' unless count.is_a?(Integer) && count >= 0

          derive.put_offset(count)
        end

        def select(*cols)
          project(cols)
        end

        def columns(*cols)
          project(cols)
        end

        def distinct
          derive.put_distinct(true)
        end

        def group(*cols)
          raise ArgumentError, 'group' if cols.empty? || !cols.all?(Col)

          derive.put_groups(cols)
        end

        def having(expr)
          raise ArgumentError, 'having' if @groups.empty? || expr.is_a?(String) || !expr.is_a?(Pred)

          derive.put_having(expr)
        end

        def from(other)
          raise ArgumentError, 'from' unless other.is_a?(Relation)

          derive.put_source(other)
        end

        def preload(name, child = nil)
          assoc = @model.association(name)
          raise ArgumentError, 'preload' if assoc.nil?

          child = preload_child(assoc[2], child)
          check_preload(assoc, child)
          derive.add_preload([name, child, assoc])
        end

        def project(cols)
          raise ArgumentError, 'select' if cols.empty? || !cols.all?(Col)

          derive.put_picks(cols)
        end

        def add_join(kind, other, on_expr, alias_name)
          raise ArgumentError, 'join' unless other.is_a?(Class)
          raise ArgumentError, 'on string' if on_expr.is_a?(String)
          raise ArgumentError, 'on' if kind != :cross && !on_expr.is_a?(Pred)

          derive.put_joins(@joins + [Join.new(kind, other, on_expr, alias_name)])
        end

        def pk_orders
          @model.primary_key.map { |key| Col.new(@model.table_alias, key).asc }
        end

        def plain_child?(child)
          bare_filters?(child) && bare_shape?(child)
        end

        private

        def preload_child(other, child)
          return other.all if child.nil?
          raise ArgumentError, 'preload' unless child.is_a?(Relation)
          raise ArgumentError, 'preload' if child.model != other

          child
        end

        def check_preload(assoc, child)
          raise Unsupported, 'preload' unless plain_child?(child)
          raise Unsupported, 'preload' if assoc[1] == :one && !child.limit_n.nil?
          raise Unsupported, 'preload' if !child.limit_n.nil? && child.orders.empty?
        end

        def bare_filters?(child)
          child.pred.nil? && child.having_node.nil? && child.join_nodes.empty? && child.groups.empty?
        end

        def bare_shape?(child)
          child.offset_n.nil? && child.source.nil? && child.picks.nil? && child.distinct_on != true
        end
      end

      module Joining
        def inner_join(other, on:)
          add_join(:inner, other, on, other.table_alias)
        end

        def joins(other, on:)
          inner_join(other, on: on)
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
      end

      module Reading
        def compile(mode)
          Sql.emit(@model.dialect, self, mode)
        end

        def to_sql
          compile(:rows)[0]
        end

        def to_binds
          compile(:rows)[1]
        end

        def to_a
          run(:rows)
        end

        def models
          raise Unsupported, 'models' if @joins.length.positive? || !@picks.nil? || !@source.nil?

          parents = row_models(run(:rows), pick_names)
          attach_preloads(parents) if @preloads.length.positive?
          parents
        end

        def each
          rows = to_a
          names = pick_names
          i = 0
          while i < rows.length
            yield View::Row.new(names, rows[i])
            i += 1
          end
          nil
        end

        def collect
          rows = to_a
          names = pick_names
          out = []
          i = 0
          while i < rows.length
            out << yield(View::Row.new(names, rows[i]))
            i += 1
          end
          out
        end

        def map(&)
          collect(&)
        end

        def stream
          names = pick_names
          sql, binds = compile(:rows)
          Scope.lease do |conn|
            conn.each_row(sql, binds) { |row| yield View::Row.new(names, row) }
          end
          nil
        end

        def pluck(*cols)
          rel = project(cols)
          return rel.run(:rows) unless cols.length == 1

          compiled = rel.compile(:rows)
          Scope.lease { |conn| conn.pluck_column(compiled[0], compiled[1]) }
        end

        def pick(col)
          rel = self
          rel = rel.order(*pk_orders) if rel.orders.empty?
          raise NonDeterministicQuery, 'pick' if rel.orders.empty?

          rows = rel.limit(1).project([col]).run(:rows)
          return nil if rows.empty?

          rows[0][0]
        end

        def ids
          keys = @model.primary_key
          raise NonDeterministicQuery, 'ids' if keys.empty?

          project(keys.map { |key| Col.new(@model.table_alias, key) }).run(:rows)
        end

        def run(mode)
          compiled = compile(mode)
          Scope.lease { |conn| conn.exec(compiled[0], compiled[1]) }
        end

        def pick_names
          (@picks || Sql.all_cols(self)).map(&:name)
        end

        private

        def row_models(raw, names)
          parents = []
          i = 0
          while i < raw.length
            parents << @model.restore(names_hash(names, raw[i]))
            i += 1
          end
          parents
        end

        def names_hash(names, row)
          attrs = {}
          c = 0
          while c < names.length
            attrs[names[c]] = row[c]
            c += 1
          end
          attrs
        end
      end

      module Counting
        def exists?
          rows = run(:exists)
          rows.length.positive?
        end

        def first
          rows = limit(1).run(:rows)
          return nil if rows.empty?

          View::Row.new(pick_names, rows[0])
        end

        def first!
          row = first
          raise NotFound, @model.table_name if row.nil?

          row
        end

        def count
          rows = run(:count)
          return grouped(rows) if @groups.length.positive?
          return 0 if rows.empty?

          rows[0][0].to_i
        end

        def count_rows
          derive.put_groups([]).put_having(nil).put_orders([]).put_limit(nil).put_offset(nil).put_distinct(false).count
        end

        def count_root
          raise UnknownRootIdentity, 'root' if @joins.any? { |join| %i[full right].include?(join.kind) }
          raise UnknownRootIdentity, 'root' if @model.primary_key.length != 1

          rows = run(:root)
          return 0 if rows.empty?

          rows[0][0].to_i
        end

        def sum(col)
          agg_decimal('SUM', col)
        end

        def avg(col)
          agg_decimal('AVG', col)
        end

        def average(col)
          avg(col)
        end

        def sum_or_zero(col)
          value = sum(col)
          return ExactDecimal.parse('0') if value.nil?

          value
        end

        def min(col)
          agg_text('MIN', col)
        end

        def max(col)
          agg_text('MAX', col)
        end

        def agg_text(function, col)
          raise ArgumentError, 'aggregate' unless col.is_a?(Col)
          raise Unsupported, 'aggregate' if @groups.length.positive?

          binds = []
          sql = aggregate_sql(function, col, binds)
          rows = Scope.lease { |conn| conn.exec(sql, binds) }
          return nil if rows.empty? || rows[0][0].nil?

          rows[0][0]
        end

        def agg_decimal(function, col)
          value = agg_text(function, col)
          return nil if value.nil?
          return value if value.is_a?(ExactDecimal) || value.is_a?(Float)
          return ExactDecimal.from_i(value) if value.is_a?(Integer)

          ExactDecimal.parse(value.to_s)
        end

        private

        def aggregate_sql(function, col, binds)
          dialect = @model.dialect
          target = Sql.col_sql(dialect, col, false, nil)
          from = Sql.from_sql(dialect, self, binds)
          "SELECT #{function}(#{target}) FROM #{from}#{Sql.where_sql(dialect, self, binds, false)}"
        end

        def grouped(rows)
          width = @groups.length
          GroupedResult.new(rows.map { |row| [row.first(width), row[width].to_i] })
        end
      end

      module Preloading
        private

        def attach_preloads(parents)
          packed = @model.dialect == :postgres ? pipeline_fetch(parents) : fetch_all(parents)
          i = 0
          while i < packed.length
            publish_assoc(parents, @preloads[i], packed[i])
            i += 1
          end
          nil
        end

        def fetch_all(parents) = @preloads.map { |entry| fetch_assoc(parents, entry) }

        def pipeline_fetch(parents)
          queries = @preloads.map { |entry| preload_query(parents, entry) }
          raws = queries.any? ? Scope.lease { |conn| conn.pipeline_batch(queries) } : nil
          Array.new(@preloads.length) { |i| pack_assoc(parents, @preloads[i], raw_at(raws, queries, i)) }
        end

        def raw_at(raws, queries, index)
          return nil if raws.nil? || queries[index].nil?

          raws[index]
        end

        def fetch_assoc(parents, entry)
          query = preload_query(parents, entry)
          raw = query.nil? ? nil : Scope.lease { |conn| conn.exec(query[0], query[1]) }
          pack_assoc(parents, entry, raw)
        end

        def preload_query(parents, entry)
          assoc = entry[2]
          if assoc[1] == :many
            many_query(parents, assoc[2], assoc[3], entry[1])
          else
            one_query(parents, assoc[2], assoc[3])
          end
        end

        def many_query(parents, other, foreign_key, child)
          return nil if parents.empty?

          keys = parent_keys(parents)
          extra = child.limit_n.nil? ? 0 : 1
          raise CapacityError, 'binds' if keys.length > bind_room(extra)

          [many_sql(child.model.dialect, other, foreign_key, child, keys.length), key_binds(keys, child.limit_n)]
        end

        def one_query(parents, other, foreign_key)
          raise Unsupported, 'preload' if other.primary_key.length != 1
          return nil if parents.empty?

          keys = foreign_keys(parents, foreign_key)
          return nil if keys.empty?
          raise CapacityError, 'binds' if keys.length > bind_room(0)

          [one_sql(other, keys.length), keys]
        end

        def one_sql(other, count)
          dialect = other.dialect
          key = Sql.quote(dialect, other.primary_key[0])
          table = Sql.quote(dialect, other.table_name)
          "SELECT #{quoted_cols(dialect, other)} FROM #{table} WHERE #{key} IN (#{in_placeholders(dialect, count)})"
        end

        def pack_assoc(parents, entry, raw)
          assoc = entry[2]
          if assoc[1] == :many
            pack_many(parents, assoc[2], assoc[3], raw)
          else
            pack_one(parents, assoc[2], assoc[3], raw)
          end
        end

        def pack_many(parents, other, foreign_key, raw)
          packed = Array.new(parents.length) { [] }
          return packed if raw.nil?

          fk_at = column_at(other, foreign_key)
          i = 0
          while i < raw.length
            place_child(packed, parents, other, raw[i], fk_at)
            i += 1
          end
          packed
        end

        def place_child(packed, parents, other, row, fk_at)
          return if row[fk_at].nil?

          slot = parent_slot(parents, row[fk_at])
          packed[slot] << other.restore(names_hash(other.columns, row)) unless slot.nil?
        end

        def pack_one(parents, other, foreign_key, raw)
          return Array.new(parents.length) if raw.nil?

          pk = other.primary_key[0]
          found = raw.map { |row| other.restore(names_hash(other.columns, row)) }
          parents.map do |parent|
            value = parent.attrs[foreign_key]
            value.nil? ? nil : match_model(found, pk, value)
          end
        end

        def publish_assoc(parents, entry, rows)
          i = 0
          while i < parents.length
            parents[i].remember(entry[0], rows[i])
            i += 1
          end
        end
      end

      module PreloadSql
        private

        def parent_keys(parents)
          raise Unsupported, 'preload' if @model.primary_key.length != 1

          key = @model.primary_key[0]
          parents.map do |parent|
            value = parent.attrs[key]
            raise Unsupported, 'preload' if value.nil?

            value
          end
        end

        def foreign_keys(parents, foreign_key)
          out = []
          seen = []
          parents.each do |parent|
            value = parent.attrs[foreign_key]
            next if value.nil? || seen.include?(value.to_s)

            seen << value.to_s
            out << value
          end
          out
        end

        def parent_slot(parents, value)
          key = @model.primary_key[0]
          want = value.to_s
          parents.index { |parent| parent.attrs[key].to_s == want }
        end

        def match_model(found, primary, value)
          want = value.to_s
          found.find { |model| model.attrs[primary].to_s == want }
        end

        def bind_room(extra)
          32_767 - extra
        end

        def many_sql(dialect, other, foreign_key, child, key_count)
          cols = quoted_cols(dialect, other)
          table = Sql.quote(dialect, other.table_name)
          fk = Sql.quote(dialect, foreign_key)
          where_in = "#{fk} IN (#{in_placeholders(dialect, key_count)})"
          return "SELECT #{cols} FROM #{table} WHERE #{where_in}" if child.limit_n.nil?

          window = "ROW_NUMBER() OVER (PARTITION BY #{fk} ORDER BY #{window_order(dialect, other, child)}) AS kiln_rn"
          inner = "SELECT #{cols}, #{window} FROM #{table} WHERE #{where_in}"
          "SELECT #{cols} FROM (#{inner}) kiln_pre WHERE kiln_rn <= #{limit_placeholder(dialect, key_count)}"
        end

        def window_order(dialect, other, child)
          terms = child.orders.map { |order| window_term(dialect, other, order) }
          terms.concat(key_terms(dialect, other, child))
          raise Unsupported, 'preload' if terms.empty?

          terms.join(', ')
        end

        def window_term(dialect, other, order)
          raise ArgumentError, 'order' unless other.column?(order.col.name)

          "#{Sql.quote(dialect, order.col.name)}#{order.ascending ? ' ASC' : ' DESC'}"
        end

        def key_terms(dialect, other, child)
          keys = other.primary_key.reject { |key| child.orders.any? { |order| order.col.name == key } }
          keys.map { |key| "#{Sql.quote(dialect, key)} ASC" }
        end

        def quoted_cols(dialect, model)
          model.columns.map { |name| Sql.quote(dialect, name) }.join(', ')
        end

        def in_placeholders(dialect, count)
          Array.new(count) { |i| dialect == :postgres ? "$#{i + 1}" : '?' }.join(', ')
        end

        def limit_placeholder(dialect, key_count)
          return '?' if dialect != :postgres

          "$#{key_count + 1}"
        end

        def key_binds(keys, limit_n)
          limit_n.nil? ? keys.dup : keys + [limit_n]
        end

        def column_at(model, name)
          model.columns.index(name) || raise(ArgumentError, 'column')
        end
      end

      include State
      include Building
      include Joining
      include Reading
      include Counting
      include Preloading
      include PreloadSql

      attr_reader :model, :pred, :groups, :orders, :limit_n, :offset_n, :picks, :distinct_on, :source

      def initialize(model, base = nil)
        @model = model
        base ? copy_state(base) : blank_state
      end

      class << self
        def blank(model)
          new(model)
        end

        def copy_list(list)
          list.dup
        end
      end

      def add_preload(entry)
        @preloads << entry
        self
      end

      def join_nodes
        @joins
      end

      def having_node
        @having
      end

      private

      def derive
        Relation.new(@model, self)
      end

      def copy_state(base)
        @joins = base.join_nodes
        @pred = base.pred
        @groups = base.groups
        @having = base.having_node
        @orders = base.orders
        copy_window(base)
        @preloads = Relation.copy_list(base.preload_list)
      end

      def copy_window(base)
        @limit_n = base.limit_n
        @offset_n = base.offset_n
        @picks = base.picks
        @distinct_on = base.distinct_on
        @source = base.source
      end

      def blank_state
        @joins = []
        @pred = nil
        @groups = []
        @having = nil
        @orders = []
        @preloads = []
        blank_window
      end

      def blank_window
        @limit_n = nil
        @offset_n = nil
        @picks = nil
        @distinct_on = false
        @source = nil
      end
    end

    class GroupedResult
      def initialize(rows)
        @rows = rows
      end

      def each
        i = 0
        while i < @rows.length
          yield @rows[i][0], @rows[i][1]
          i += 1
        end
        nil
      end

      def to_a
        @rows
      end

      def keys
        out = []
        i = 0
        while i < @rows.length
          out << @rows[i][0]
          i += 1
        end
        out
      end

      def values
        out = []
        i = 0
        while i < @rows.length
          out << @rows[i][1]
          i += 1
        end
        out
      end

      def length
        @rows.length
      end
    end
  end
end
