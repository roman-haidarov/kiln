module Kiln
  module DB
    class Relation
      module Preloading
        private

        def attach_preloads(parents)
          packed = @model.dialect == :postgres ? pipeline_fetch(parents) : fetch_all(parents)
          i = 0
          while i < packed.length
            publish_assoc(parents, @preloads[i], packed[i])
            i += 1
          end
          nil
        end

        def fetch_all(parents) = @preloads.map { |entry| fetch_assoc(parents, entry) }

        def pipeline_fetch(parents)
          queries = @preloads.map { |entry| preload_query(parents, entry) }
          raws = queries.any? ? Scope.lease { |conn| conn.pipeline_batch(queries) } : nil
          Array.new(@preloads.length) { |i| pack_assoc(parents, @preloads[i], raw_at(raws, queries, i)) }
        end

        def raw_at(raws, queries, index)
          return nil if raws.nil? || queries[index].nil?

          raws[index]
        end

        def fetch_assoc(parents, entry)
          query = preload_query(parents, entry)
          raw = query.nil? ? nil : Scope.lease { |conn| conn.exec(query[0], query[1]) }
          pack_assoc(parents, entry, raw)
        end

        def preload_query(parents, entry)
          assoc = entry[2]
          if assoc[1] == :many
            many_query(parents, assoc[2], assoc[3], entry[1])
          else
            one_query(parents, assoc[2], assoc[3])
          end
        end

        def many_query(parents, other, foreign_key, child)
          return nil if parents.empty?

          keys = parent_keys(parents)
          extra = child.limit_n.nil? ? 0 : 1
          raise CapacityError, 'binds' if keys.length > bind_room(extra)

          [many_sql(child.model.dialect, other, foreign_key, child, keys.length), key_binds(keys, child.limit_n)]
        end

        def one_query(parents, other, foreign_key)
          raise Unsupported, 'preload' if other.primary_key.length != 1
          return nil if parents.empty?

          keys = foreign_keys(parents, foreign_key)
          return nil if keys.empty?
          raise CapacityError, 'binds' if keys.length > bind_room(0)

          [one_sql(other, keys.length), keys]
        end

        def one_sql(other, count)
          dialect = other.dialect
          key = Sql.quote(dialect, other.primary_key[0])
          table = Sql.quote(dialect, other.table_name)
          "SELECT #{quoted_cols(dialect, other)} FROM #{table} WHERE #{key} IN (#{in_placeholders(dialect, count)})"
        end

        def pack_assoc(parents, entry, raw)
          assoc = entry[2]
          if assoc[1] == :many
            pack_many(parents, assoc[2], assoc[3], raw)
          else
            pack_one(parents, assoc[2], assoc[3], raw)
          end
        end

        def pack_many(parents, other, foreign_key, raw)
          packed = Array.new(parents.length) { [] }
          return packed if raw.nil?

          fk_at = column_at(other, foreign_key)
          i = 0
          while i < raw.length
            place_child(packed, parents, other, raw[i], fk_at)
            i += 1
          end
          packed
        end

        def place_child(packed, parents, other, row, fk_at)
          return if row[fk_at].nil?

          slot = parent_slot(parents, row[fk_at])
          packed[slot] << other.restore(names_hash(other.columns, row)) unless slot.nil?
        end

        def pack_one(parents, other, foreign_key, raw)
          return Array.new(parents.length) if raw.nil?

          pk = other.primary_key[0]
          found = raw.map { |row| other.restore(names_hash(other.columns, row)) }
          parents.map do |parent|
            value = parent.attrs[foreign_key]
            value.nil? ? nil : match_model(found, pk, value)
          end
        end

        def publish_assoc(parents, entry, rows)
          i = 0
          while i < parents.length
            parents[i].remember(entry[0], rows[i])
            i += 1
          end
        end
      end

      module PreloadSql
        private

        def parent_keys(parents)
          raise Unsupported, 'preload' if @model.primary_key.length != 1

          key = @model.primary_key[0]
          parents.map do |parent|
            value = parent.attrs[key]
            raise Unsupported, 'preload' if value.nil?

            value
          end
        end

        def foreign_keys(parents, foreign_key)
          out = []
          seen = []
          parents.each do |parent|
            value = parent.attrs[foreign_key]
            next if value.nil? || seen.include?(value.to_s)

            seen << value.to_s
            out << value
          end
          out
        end

        def parent_slot(parents, value)
          key = @model.primary_key[0]
          want = value.to_s
          parents.index { |parent| parent.attrs[key].to_s == want }
        end

        def match_model(found, primary, value)
          want = value.to_s
          found.find { |model| model.attrs[primary].to_s == want }
        end

        def bind_room(extra)
          32_767 - extra
        end

        def many_sql(dialect, other, foreign_key, child, key_count)
          cols = quoted_cols(dialect, other)
          table = Sql.quote(dialect, other.table_name)
          fk = Sql.quote(dialect, foreign_key)
          where_in = "#{fk} IN (#{in_placeholders(dialect, key_count)})"
          return "SELECT #{cols} FROM #{table} WHERE #{where_in}" if child.limit_n.nil?

          window = "ROW_NUMBER() OVER (PARTITION BY #{fk} ORDER BY #{window_order(dialect, other, child)}) AS kiln_rn"
          inner = "SELECT #{cols}, #{window} FROM #{table} WHERE #{where_in}"
          "SELECT #{cols} FROM (#{inner}) kiln_pre WHERE kiln_rn <= #{limit_placeholder(dialect, key_count)}"
        end

        def window_order(dialect, other, child)
          terms = child.orders.map { |order| window_term(dialect, other, order) }
          terms.concat(key_terms(dialect, other, child))
          raise Unsupported, 'preload' if terms.empty?

          terms.join(', ')
        end

        def window_term(dialect, other, order)
          raise ArgumentError, 'order' unless other.column?(order.col.name)

          "#{Sql.quote(dialect, order.col.name)}#{order.ascending ? ' ASC' : ' DESC'}"
        end

        def key_terms(dialect, other, child)
          keys = other.primary_key.reject { |key| child.orders.any? { |order| order.col.name == key } }
          keys.map { |key| "#{Sql.quote(dialect, key)} ASC" }
        end

        def quoted_cols(dialect, model)
          model.columns.map { |name| Sql.quote(dialect, name) }.join(', ')
        end

        def in_placeholders(dialect, count)
          Array.new(count) { |i| dialect == :postgres ? "$#{i + 1}" : '?' }.join(', ')
        end

        def limit_placeholder(dialect, key_count)
          return '?' if dialect != :postgres

          "$#{key_count + 1}"
        end

        def key_binds(keys, limit_n)
          limit_n.nil? ? keys.dup : keys + [limit_n]
        end

        def column_at(model, name)
          model.columns.index(name) || raise(ArgumentError, 'column')
        end
      end
    end
  end
end
