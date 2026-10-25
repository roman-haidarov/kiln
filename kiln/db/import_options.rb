module Kiln
  module DB
    ImportSettings = Struct.new(:updates, :target, :constraint, :batch_size, :return_columns, :timestamps)
    ImportRow = Struct.new(:record, :attrs)

    module ImportOptions
      UPDATE_KEYS = %i[columns conflict_target constraint_name].freeze
      CREATE_STAMPS = %w[created_at created_on].freeze
      UPDATE_STAMPS = %w[updated_at updated_on].freeze

      class << self
        def settings(model, options)
          update = options[:on_duplicate_key_update]
          updates, target, constraint = update_settings(model, update)
          timestamps = options[:timestamps] != false
          updates = stamp_updates(model, updates) if timestamps && !updates.nil?
          size = options[:batch_size]
          raise ArgumentError, 'batch_size' unless size.nil? || (size.is_a?(Integer) && size.positive?)

          returning = options[:returning]
          returned = returning == true || returning == false || returning.nil? ? nil : names(model, returning)
          ImportSettings.new(updates, target, constraint, size, returned, timestamps)
        end

        def ignore?(options)
          value = options[:on_duplicate_key_ignore]
          raise ArgumentError, 'ignore' if options.key?(:ignore) && !value.nil? && options[:ignore] != value

          value = options[:ignore] if value.nil?
          raise ArgumentError, 'ignore' unless value.nil? || value == true || value == false

          value == true
        end

        def update?(options)
          value = options[:on_duplicate_key_update]
          !value.nil? && value != false
        end

        def input(model, columns, rows)
          list = names(model, columns)
          raise ArgumentError, 'rows' unless rows.is_a?(Array)

          rows.map { |row| selected_row(list, row) }
        end

        def names(model, values)
          list = values.is_a?(Array) ? values : [values]
          raise ArgumentError, 'columns' if list.empty?

          result = list.map { |name| column(model, name) }
          raise ArgumentError, 'duplicate column' unless result.uniq.length == result.length

          result
        end

        private

        def stamp_updates(model, updates)
          names = updates.map { |pair| pair[0] }
          extra = UPDATE_STAMPS.select { |name| model.column?(name) && !names.include?(name) }
          updates + extra.map { |name| [name, name] }
        end

        def column(model, value)
          raise ArgumentError, 'column' unless value.is_a?(String) || value.is_a?(Symbol)

          text = value.to_s
          raise ArgumentError, 'column' unless model.column?(text)

          text
        end

        def update_settings(model, value)
          return [nil, model.primary_key, nil] if value.nil? || value == false || value == true || value == :all

          target = model.primary_key
          constraint = nil
          if value.is_a?(Hash) && value.key?(:columns)
            raise ArgumentError, 'update options' unless (value.keys - UPDATE_KEYS).empty?
            raise ArgumentError, 'conflict target' if value.key?(:conflict_target) && value.key?(:constraint_name)

            target = names(model, value[:conflict_target]) if value.key?(:conflict_target)
            constraint = value[:constraint_name].to_s if value.key?(:constraint_name)
            raise ArgumentError, 'constraint' unless constraint.nil? || Ident.ok?(constraint)

            value = value[:columns]
          end
          if model.dialect != :postgres && (target != model.primary_key || !constraint.nil?)
            raise ArgumentError, 'conflict target is PostgreSQL only'
          end
          return [nil, target, constraint] if value == :all || value == true

          updates = if value.is_a?(Hash)
                      mapped_columns(model, value)
                    elsif value.is_a?(Array)
                      names(model, value).map { |name| [name, name] }
                    else
                      raise ArgumentError, 'update columns'
                    end
          raise ArgumentError, 'update columns' if updates.empty?
          [updates, target, constraint]
        end

        def mapped_columns(model, values)
          out = values.map { |key, value| [column(model, key), column(model, value)] }
          raise ArgumentError, 'duplicate column' unless out.map { |pair| pair[0] }.uniq.length == out.length

          out
        end

        def selected_row(columns, row)
          attrs = {}
          if row.is_a?(Array)
            raise ArgumentError, 'row width' unless row.length == columns.length

            columns.each_with_index { |name, index| attrs[name] = row[index] }
            return attrs
          end

          source = Import.row_hash(row)
          columns.each do |name|
            found = Import.field(source, name)
            raise ArgumentError, 'missing column' if found.nil?

            attrs[name] = found[1]
          end
          row.is_a?(Model) ? ImportRow.new(row, attrs) : attrs
        end
      end
    end
  end
end
