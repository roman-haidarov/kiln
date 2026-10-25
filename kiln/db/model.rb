module Kiln
  module DB
    TableInfo = Struct.new(:dialect, :name, :columns, :primary_key, :alias_name)

    class Model
      module Saving
        def validate = nil
        def before_save = nil
        def after_save = nil

        def save
          store_record(false)
        end

        def save!
          store_record(true)
        end

        def store_record(bang)
          err = validate
          unless err.nil?
            raise RecordInvalid, err if bang

            return false
          end
          write_record
        end

        private

        def write_record
          before_save
          @persisted ? update_row : insert_row
          @persisted = true
          @dirty = []
          after_save
          @persisted
        end

        def insert_row
          model = self.class
          key = generated_key(model)
          names = model.columns.select { |col| @attrs.key?(col) && col != key }
          raise ArgumentError, 'save' if names.empty?

          sql, binds = insert_statement(model, names, key)
          Scope.lease { |conn| capture_key(conn, conn.exec(sql, binds), key) }
          nil
        end

        def insert_statement(model, names, key)
          dialect = model.dialect
          binds = []
          marks = bind_marks(dialect, names, binds)
          table = Sql.quote(dialect, model.table_name)
          sql = "INSERT INTO #{table} (#{quoted_list(dialect, names)}) VALUES (#{marks})"
          sql += " RETURNING #{Sql.quote(dialect, key)}" if !key.nil? && dialect == :postgres
          [sql, binds]
        end

        def capture_key(conn, rows, key)
          return if key.nil?

          rows = conn.exec('SELECT LAST_INSERT_ID()', []) if self.class.dialect != :postgres
          value = rows.length.positive? ? rows[0][0] : nil
          @attrs[key] = value if !value.nil? && value != 0
        end

        def generated_key(model)
          keys = model.primary_key
          return nil if keys.length != 1
          return nil if @attrs.key?(keys[0]) && !@attrs[keys[0]].nil?

          keys[0]
        end

        def update_row
          model = self.class
          names = @dirty.reject { |name| key_col?(model, name) }
          return if names.empty?

          keys = model.primary_key
          raise ArgumentError, 'save' if keys.empty? || keys.any? { |name| @attrs[name].nil? }

          sql, binds = update_statement(model, names, keys)
          Scope.lease { |conn| conn.exec(sql, binds) }
          nil
        end

        def update_statement(model, names, keys)
          dialect = model.dialect
          binds = []
          sets = assignments(dialect, names, binds).join(', ')
          wheres = assignments(dialect, keys, binds).join(' AND ')
          ["UPDATE #{Sql.quote(dialect, model.table_name)} SET #{sets} WHERE #{wheres}", binds]
        end

        def quoted_list(dialect, names) = names.map { |name| Sql.quote(dialect, name) }.join(', ')

        def bind_marks(dialect, names, binds)
          out = []
          i = 0
          while i < names.length
            binds << @attrs[names[i]]
            out << Sql.placeholder(dialect, binds)
            i += 1
          end
          out.join(', ')
        end

        def assignments(dialect, names, binds)
          out = []
          i = 0
          while i < names.length
            binds << @attrs[names[i]]
            out << "#{Sql.quote(dialect, names[i])} = #{Sql.placeholder(dialect, binds)}"
            i += 1
          end
          out
        end

        def key_col?(model, name) = model.primary_key.include?(name)
      end

      include Saving

      attr_reader :attrs

      def initialize(attrs, persisted = nil)
        raise ArgumentError, 'attrs' unless attrs.is_a?(Hash)

        @attrs = {}
        @dirty = []
        @loaded = {}
        @persisted = persisted == true
        attrs.each { |key, value| load_attr(key, value) }
      end

      def assign(name, value)
        raise ArgumentError, 'column' unless self.class.column?(name)

        @attrs[name] = value
        @dirty << name unless @dirty.include?(name)
      end

      def assoc(name)
        raise NotLoaded, "#{self.class.table_name} #{name}" unless @loaded.key?(name)

        @loaded[name]
      end

      def remember(name, value) = @loaded[name] = value

      class << self
        def define_table(dialect, table, columns, primary_key, table_alias)
          raise ArgumentError, 'dialect' unless %i[postgres mysql].include?(dialect)
          raise ArgumentError, 'identifier' unless Ident.ok?(table) && Ident.ok?(table_alias)

          list = copy_names(columns)
          keys = copy_names(primary_key)
          @table = TableInfo.new(dialect, table, list, keys, table_alias)
          @associations = []
          self
        end

        def one_to_many(name, other, foreign_key) = store_assoc(name, :many, other, foreign_key)
        def belongs_to(name, other, foreign_key) = store_assoc(name, :one, other, foreign_key)

        alias has_many one_to_many

        def association(name)
          list = @associations
          return nil if list.nil?

          list.find { |entry| entry[0] == name }
        end

        def restore(attrs) = new(attrs, true)

        def store_assoc(name, kind, other, foreign_key)
          check_assoc(name, other, foreign_key)
          list = @associations
          kept = list.nil? ? [] : list.reject { |entry| entry[0] == name }
          kept << [name, kind, other, foreign_key]
          @associations = kept
          self
        end

        def dialect = @table.dialect
        def table_name = @table.name
        def columns = @table.columns
        def primary_key = @table.primary_key
        def table_alias = @table.alias_name

        def col(name)
          raise ArgumentError, 'column' unless column?(name)

          Col.new(table_alias, name)
        end

        def column?(name) = columns.include?(name)

        def model = self
        def table = Table.new(self)
        def arel_table = self.table
        def all = Relation.blank(self)
        def where(expr) = self.all.where(expr)
        def select(*expressions) = self.all.select(*expressions)
        def order(*expressions) = self.all.order(*expressions)
        def group(*expressions) = self.all.group(*expressions)
        def joins(other, on: nil) = self.all.joins(other, on: on)
        def limit(count) = self.all.limit(count)
        def offset(count) = self.all.offset(count)
        def distinct = self.all.distinct
        def from(other) = self.all.from(other)
        def import(rows, values = nil, options = nil) = Import.call(self, rows, values, options, false)

        def import!(rows, values = nil, options = nil) = Import.call(self, rows, values, options, true)

        alias bulk_import import
        alias bulk_import! import!

        def copy_names(names)
          raise ArgumentError, 'names' unless names.is_a?(Array)
          raise ArgumentError, 'identifier' unless names.all? { |name| Ident.ok?(name) }

          names.dup
        end

        private

        def check_assoc(name, other, foreign_key)
          raise ArgumentError, 'assoc' unless name.is_a?(Symbol)
          raise ArgumentError, 'assoc' unless other.is_a?(Class)
          raise ArgumentError, 'identifier' unless Ident.ok?(foreign_key)
        end
      end

      private

      def load_attr(key, value)
        name = key.is_a?(Symbol) ? key.to_s : key
        raise ArgumentError, 'column' unless self.class.column?(name)

        @attrs[name] = value
        @dirty << name unless @persisted
      end
    end
  end
end
