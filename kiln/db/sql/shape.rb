module Kiln
  module DB
    module Sql
      module Shape
        CAPACITY = 4096
        IN_LIMIT = 32
        MAX_KEY_BYTES = 8192
        MAX_ENTRY_BYTES = 16_384
        MODE_CODES = { rows: 'r'.freeze, count: 'c'.freeze, exists: 'e'.freeze,
                       exists_sub: 's'.freeze, root: 'o'.freeze }.freeze

        class Store
          def initialize
            @current = {}
            @previous = {}
            @lock = Mutex.new
          end

          def fetch(key)
            @lock.lock
            begin
              sql = @current[key]
              return sql unless sql.nil?

              sql = @previous[key]
              insert(key.dup.freeze, sql) unless sql.nil?
              sql
            ensure
              @lock.unlock
            end
          end

          def store(key, sql)
            return if key.bytesize + sql.bytesize > MAX_ENTRY_BYTES

            @lock.lock
            begin
              insert(key.dup.freeze, sql.dup.freeze)
            ensure
              @lock.unlock
            end
            nil
          end

          def size
            @lock.lock
            begin
              @current.length + @previous.length
            ensure
              @lock.unlock
            end
          end

          def clear
            @lock.lock
            begin
              @current = {}
              @previous = {}
            ensure
              @lock.unlock
            end
            nil
          end

          private

          def insert(key, sql)
            if @current.length >= CAPACITY / 2 && !@current.key?(key)
              @previous = @current
              @current = {}
            end
            @current[key] = sql
          end
        end

        STORE = Store.new
        private_constant :MODE_CODES, :Store, :STORE

        class << self
          def key(dialect, rel, mode, binds)
            return nil unless dialect == :postgres || dialect == :mysql
            return nil unless rel.is_a?(Relation)
            return nil unless plain_source?(rel)
            return nil unless rel.offset_n.nil?

            code = MODE_CODES[mode]
            return nil if code.nil?

            text = String.new
            text << (dialect == :postgres ? 'P' : 'M') << code
            return nil unless model(text, rel, mode)
            text << (rel.distinct_on ? '|D' : '|d')
            return nil unless picks(text, rel.picks)
            return nil unless orders(text, rel.orders)

            number(text, '|L', rel.limit_n)
            unless rel.pred.nil?
              text << '|W'
              return nil unless pred(text, rel.pred, binds)
            end
            text.bytesize <= MAX_KEY_BYTES ? text : nil
          end

          def fetch(key) = STORE.fetch(key)
          def store(key, sql) = STORE.store(key, sql)
          def size = STORE.size
          def clear = STORE.clear

          private

          def plain_source?(rel)
            rel.source.nil? && rel.join_nodes.empty? && rel.groups.empty? && rel.having_node.nil? && rel.ctes.empty?
          end

          def model(text, rel, mode)
            source = rel.model
            text << '|T'
            return false unless token(text, source.table_name) && token(text, rel.table_alias)
            return false if mode == :root && !names(text, '|K', source.primary_key)
            return false if rel.picks.nil? && !names(text, '|C', source.columns)

            true
          end

          def names(text, tag, list)
            text << tag << list.length.to_s << ':'
            i = 0
            while i < list.length
              return false unless token(text, list[i])
              i += 1
            end
            true
          end

          def number(text, tag, value)
            return if value.nil?

            text << tag << value.to_s
          end

          def col(text, node)
            return false unless node.is_a?(Col)

            text << '['
            return false unless token(text, node.scope) && token(text, node.name)

            text << ']'
            true
          end

          def token(text, value)
            return false unless Ident.ok?(value)

            text << value << ':'
            true
          end

          def picks(text, list)
            if list.nil?
              text << '|*'
              return true
            end
            text << '|S'
            i = 0
            while i < list.length
              item = list[i]
              if item.is_a?(Aliased)
                return false unless col(text, item.expr)

                text << '>'
                return false unless token(text, item.name)
              else
                return false unless col(text, item)
              end
              i += 1
            end
            true
          end

          def orders(text, list)
            return true if list.empty?

            text << '|R'
            i = 0
            while i < list.length
              order = list[i]
              return false unless order.is_a?(Order)

              text << (order.ascending ? '+' : '-')
              return false unless col(text, order.col)

              i += 1
            end
            true
          end

          def operand(text, node, binds)
            if node.is_a?(Bound)
              text << '?'
              binds << node.value
              return true
            end
            col(text, node)
          end

          def pred(text, node, binds)
            if node.is_a?(And) || node.is_a?(Or)
              text << (node.is_a?(And) ? '(&' : '(|')
              return false unless pred(text, node.left, binds)
              return false unless pred(text, node.right, binds)

              text << ')'
              return true
            end
            if node.is_a?(Not)
              text << '(!'
              return false unless pred(text, node.inner, binds)

              text << ')'
              return true
            end
            leaf(text, node, binds)
          end

          def leaf(text, node, binds)
            return compare(text, node, binds) if node.is_a?(Cmp)
            return null_check(text, node) if node.is_a?(NullPred)
            return in_list(text, node, binds) if node.is_a?(InPred)
            return between(text, node, binds) if node.is_a?(Between)
            if node.is_a?(Truth)
              text << (node.value ? 'T' : 'F')
              return true
            end
            false
          end

          def compare(text, node, binds)
            op = CMP_OPS[node.op]
            return false if op.nil?

            text << 'c'
            return false unless operand(text, node.left, binds)

            text << op
            operand(text, node.right, binds)
          end

          def null_check(text, node)
            text << (node.wants_null ? 'n' : 'N')
            col(text, node.col)
          end

          def in_list(text, node, binds)
            values = node.values
            return false unless values.is_a?(Array)

            text << (node.negated ? 'X' : 'I')
            if values.empty?
              text << '0'
              return true
            end
            return false if values.length > IN_LIMIT
            return false unless col(text, node.col)

            i = 0
            while i < values.length
              value = values[i]
              return false if value.is_a?(Expr) || value.is_a?(Relation) || value.is_a?(SetQuery)

              i += 1
            end
            text << values.length.to_s
            i = 0
            while i < values.length
              binds << values[i]
              i += 1
            end
            true
          end

          def between(text, node, binds)
            text << 'b'
            return false unless col(text, node.col)
            return false unless operand(text, node.left, binds)

            text << '~'
            operand(text, node.right, binds)
          end
        end
      end
    end
  end
end
