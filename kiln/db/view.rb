module Kiln
  module DB
    module View
      class Row
        def initialize(names, values)
          @names = names
          @values = values
        end

        def [](index)
          @values[index]
        end

        def get(name)
          i = 0
          while i < @names.length
            return @values[i] if @names[i] == name

            i += 1
          end
          nil
        end

        def length
          @values.length
        end
      end
    end
  end
end
