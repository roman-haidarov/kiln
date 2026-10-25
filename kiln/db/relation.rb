require 'kiln/db/relation/state'
require 'kiln/db/relation/building'
require 'kiln/db/relation/joining'
require 'kiln/db/relation/reading'
require 'kiln/db/relation/counting'
require 'kiln/db/relation/preloading'

module Kiln
  module DB
    class Relation
      include QueryComposition
      include State
      include Building
      include Joining
      include Reading
      include Counting
      include Preloading
      include PreloadSql

      attr_reader :model, :pred, :groups, :orders, :limit_n, :offset_n, :picks, :distinct_on, :source, :ctes

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

      def table_alias
        @source.is_a?(Table) ? @source.table_alias : @model.table_alias
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
        @ctes = base.ctes
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
        @ctes = []
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
