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

        def put_ctes(value)
          @ctes = value
          self
        end

        def preload_list = @preloads
      end
    end
  end
end
