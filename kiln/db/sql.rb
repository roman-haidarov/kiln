require 'kiln/db/sql/statements'
require 'kiln/db/sql/columns'
require 'kiln/db/sql/sources'
require 'kiln/db/sql/predicates'
require 'kiln/db/sql/clauses'
require 'kiln/db/sql/expressions'

module Kiln
  module DB
    module Sql
      CMP_OPS = { eq: ' = ', ne: ' <> ', gt: ' > ', gte: ' >= ', lt: ' < ', lte: ' <= ' }.freeze
      JOIN_WORDS = { inner: 'INNER JOIN', left: 'LEFT JOIN', right: 'RIGHT JOIN', full: 'FULL OUTER JOIN',
                     cross: 'CROSS JOIN' }.freeze

      extend Statements
      extend Columns
      extend Sources
      extend Predicates
      extend Clauses
      extend ExpressionsSql
    end
  end
end
