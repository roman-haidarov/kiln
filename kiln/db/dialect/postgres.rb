module Kiln
  module DB
    module Dialect
      module Postgres
        class << self
          def emit(relation, mode)
            Sql.emit(:postgres, relation, mode)
          end
        end
      end
    end
  end
end
