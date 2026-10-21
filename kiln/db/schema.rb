module Kiln
  module DB
    module Schema
      PG_COLUMNS = 'SELECT column_name, CAST(data_type AS varchar(64)), is_nullable ' \
                   'FROM information_schema.columns WHERE table_schema = $1 AND table_name = $2 ' \
                   'ORDER BY ordinal_position'.freeze
      MY_COLUMNS = 'SELECT column_name, CAST(data_type AS CHAR(64)), is_nullable ' \
                   'FROM information_schema.columns WHERE table_schema = ? AND table_name = ? ' \
                   'ORDER BY ordinal_position'.freeze
      KEY_JOIN = 'SELECT kcu.column_name FROM information_schema.table_constraints tc ' \
                 'JOIN information_schema.key_column_usage kcu ON tc.constraint_name = kcu.constraint_name ' \
                 'AND tc.table_schema = kcu.table_schema AND tc.table_name = kcu.table_name '.freeze
      PG_KEYS = "#{KEY_JOIN}WHERE tc.constraint_type = $1 AND tc.table_schema = $2 AND tc.table_name = $3 " \
                'ORDER BY kcu.ordinal_position'.freeze
      MY_KEYS = "#{KEY_JOIN}WHERE tc.constraint_type = ? AND tc.table_schema = ? AND tc.table_name = ? " \
                'ORDER BY kcu.ordinal_position'.freeze
      UNIQUE = 'SELECT index_name, column_name FROM information_schema.statistics ' \
               'WHERE table_schema = ? AND table_name = ? AND non_unique = 0 ' \
               'ORDER BY index_name, seq_in_index'.freeze

      class << self
        def columns(conn, table)
          raise ArgumentError, 'identifier' unless Ident.ok?(table)

          conn.exec(conn.dialect == :postgres ? PG_COLUMNS : MY_COLUMNS, [conn.schema_name, table])
        end

        def primary_key(conn, table)
          raise ArgumentError, 'identifier' unless Ident.ok?(table)

          conn.exec(conn.dialect == :postgres ? PG_KEYS : MY_KEYS, ['PRIMARY KEY', conn.schema_name, table])
        end

        def prove_update_key(conn, model)
          raise ArgumentError, 'update' if conn.dialect == :postgres

          groups = index_groups(unique_indexes(conn, model.table_name))
          raise AmbiguousConflict, 'update' if groups.length != 1 || groups.values.first != model.primary_key

          nil
        end

        def unique_indexes(conn, table)
          raise ArgumentError, 'identifier' unless Ident.ok?(table)
          raise ArgumentError, 'update' if conn.dialect == :postgres

          conn.exec(UNIQUE, [conn.schema_name, table])
        end

        private

        def index_groups(rows)
          groups = {}
          rows.each do |row|
            column_name = row[1]
            raise AmbiguousConflict, 'update' if [nil, ''].include?(column_name)

            group_column(groups, row[0], column_name)
          end
          groups
        end

        def group_column(groups, index_name, column_name)
          list = groups[index_name]
          if list
            list << column_name
          else
            groups[index_name] = [column_name]
          end
        end
      end
    end

    module Generate
      class << self
        def models(dialect, tables)
          raise ArgumentError, 'dialect' unless %i[postgres mysql].include?(dialect)

          tables.map { |table| model_source(dialect, table) }.join
        end

        def model_source(dialect, table)
          name = table[:name]
          raise ArgumentError, 'identifier' unless Ident.ok?(name)

          klass = camel(name)
          columns = join_list(table[:columns])
          keys = join_list(table[:primary_key])
          "class #{klass} < Kiln::DB::Model\nend\n" \
            "#{klass}.define_table(:#{dialect}, '#{name}', [#{columns}], [#{keys}], '#{name}')\n"
        end

        def join_list(names)
          raise ArgumentError, 'identifier' unless names.all? { |name| Ident.ok?(name) }

          names.map { |name| "'#{name}'" }.join(', ')
        end

        def camel(name)
          name.split('_').reject(&:empty?).map { |part| "#{part[0].upcase}#{part[1..]}" }.join
        end
      end
    end
  end
end
