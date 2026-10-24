module Kiln
  module DB
    module SchemaGuard
      PG_COPY_TABLE = 'SELECT CAST(COUNT(*) AS int) FROM pg_class c WHERE c.oid = to_regclass($1) ' \
                      "AND c.relkind IN ('r', 'p') AND NOT c.relhasrules AND NOT c.relrowsecurity " \
                      'AND NOT EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid IN ' \
                      "(c.oid, pg_partition_root(c.oid)) AND a.attidentity = 'a') " \
                      'AND NOT EXISTS (SELECT 1 FROM pg_trigger t WHERE t.tgrelid = c.oid ' \
                      'AND NOT t.tgisinternal AND (t.tgtype & 5) = 4)'.freeze
      PG_KEY_TRIGGERS = 'SELECT CAST((SELECT COUNT(*) FROM pg_trigger t ' \
                        'WHERE NOT t.tgisinternal AND (t.tgtype & 3) = 3 AND (t.tgtype & $2) <> 0 ' \
                        'AND (t.tgrelid = to_regclass($1) ' \
                        'OR t.tgrelid IN (SELECT relid FROM pg_partition_tree(to_regclass($1))))) + ' \
                        '(SELECT COUNT(*) FROM pg_class c WHERE c.oid = to_regclass($1) ' \
                        "AND (c.relhasrules OR c.relkind NOT IN ('r', 'p'))) AS int)".freeze
      MY_KEY_TRIGGERS = 'SELECT COUNT(*) FROM information_schema.triggers WHERE event_object_schema = DATABASE() ' \
                        "AND event_object_table = ? AND action_timing = 'BEFORE' " \
                        "AND (event_manipulation = 'INSERT' OR (event_manipulation = 'UPDATE' AND ? = 1))".freeze
      MY_TRIGGER_ACCESS = 'SELECT COUNT(*) FROM (SELECT GRANTEE FROM information_schema.USER_PRIVILEGES ' \
                          "WHERE PRIVILEGE_TYPE = 'TRIGGER' UNION ALL " \
                          'SELECT GRANTEE FROM information_schema.SCHEMA_PRIVILEGES ' \
                          "WHERE PRIVILEGE_TYPE = 'TRIGGER' AND TABLE_SCHEMA = DATABASE() UNION ALL " \
                          'SELECT GRANTEE FROM information_schema.TABLE_PRIVILEGES ' \
                          "WHERE PRIVILEGE_TYPE = 'TRIGGER' AND TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?) p " \
                          "WHERE GRANTEE = CONCAT(QUOTE(SUBSTRING_INDEX(CURRENT_USER(), '@', 1)), '@', " \
                          "QUOTE(SUBSTRING_INDEX(CURRENT_USER(), '@', -1)))".freeze
      MY_BASE_TABLE = 'SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() ' \
                      "AND table_name = ? AND table_type = 'BASE TABLE'".freeze
      PG_ISOLATION = "SELECT current_setting('transaction_isolation')".freeze
      LIVE_CATALOG = ['read committed', 'read uncommitted'].freeze
      TRIGGER_INSERT = 4
      TRIGGER_UPDATE = 16

      def copy_table?(conn, table)
        raise ArgumentError, 'identifier' unless Ident.ok?(table)
        return false unless locked_for_import?(conn, table)

        count_of(conn, PG_COPY_TABLE, [Sql.quote(:postgres, table)]) == 1
      end

      def prove_stable_keys(conn, table, update)
        raise ArgumentError, 'identifier' unless Ident.ok?(table)
        raise UnsupportedReturn, 'returning: trigger metadata is not stable' unless locked_for_import?(conn, table)

        prove_my_table(conn, table) if conn.dialect != :postgres
        raise UnsupportedReturn, 'returning: key trigger' if key_triggers(conn, table, update).positive?

        nil
      end

      def key_triggers(conn, table, update)
        return count_of(conn, MY_KEY_TRIGGERS, [table, update ? 1 : 0]) unless conn.dialect == :postgres

        mask = update ? TRIGGER_INSERT + TRIGGER_UPDATE : TRIGGER_INSERT
        count_of(conn, PG_KEY_TRIGGERS, [Sql.quote(:postgres, table), mask])
      end

      def locked_for_import?(conn, table)
        quoted = Sql.quote(conn.dialect, table)
        if conn.dialect != :postgres
          conn.exec("SELECT 1 FROM #{quoted} LIMIT 0", [])
          return true
        end
        conn.exec("LOCK TABLE #{quoted} IN ROW EXCLUSIVE MODE", [])
        LIVE_CATALOG.include?(conn.exec(PG_ISOLATION, [])[0][0])
      end

      private

      def prove_my_table(conn, table)
        visible = count_of(conn, MY_TRIGGER_ACCESS, [table]).positive?
        raise UnsupportedReturn, 'returning: trigger metadata is not visible' unless visible
        raise UnsupportedReturn, 'returning: base table required' unless count_of(conn, MY_BASE_TABLE, [table]) == 1
      end

      def count_of(conn, sql, binds) = conn.exec(sql, binds)[0][0].to_s.to_i
    end

    module Schema
      extend SchemaGuard

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
               'WHERE table_schema = DATABASE() AND table_name = ? AND non_unique = 0 ' \
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

          locked_for_import?(conn, model.table_name)
          groups = index_groups(unique_indexes(conn, model.table_name))
          raise AmbiguousConflict, 'update' if groups.length != 1 || groups.values.first != model.primary_key

          nil
        end

        def unique_indexes(conn, table)
          raise ArgumentError, 'identifier' unless Ident.ok?(table)
          raise ArgumentError, 'update' if conn.dialect == :postgres

          conn.exec(UNIQUE, [table])
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
