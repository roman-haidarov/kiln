module Kiln
  module DB
    module Dialect
      module Mysql
        class << self
          def emit(relation, mode)
            Sql.emit(:mysql, relation, mode)
          end
        end
      end
    end
  end
end
