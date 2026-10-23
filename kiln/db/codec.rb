module Kiln
  module DB
    module Codec
      I64_MAX_TEXT = '9223372036854775807'.freeze

      class << self
        def encode(dialect, value)
          return [nil, 1, 0] if value.nil?
          return [bool_text(dialect, value), 0, 0] if [true, false].include?(value)
          return string_param(value) if value.is_a?(String)

          [scalar_text(value), 0, 0]
        end

        def scalar_text(value)
          return value.to_s if value.is_a?(Integer) || value.is_a?(Symbol)
          return float_text(value) if value.is_a?(Float)
          return value.bind_text if numeric_value?(value)

          raise ArgumentError, "bind #{value.class}: pass a String formatted for the database"
        end

        def bool_text(dialect, value)
          if dialect == :postgres
            value ? 't' : 'f'
          else
            value ? '1' : '0'
          end
        end

        def float_text(value)
          raise ArgumentError, 'bind Float: NaN or Infinity' if value.nan? || value.infinite?

          value.to_s
        end

        def numeric_value?(value)
          value.is_a?(ExactDecimal) || value.is_a?(Int64Value) || value.is_a?(UInt64Value)
        end

        def string_param(value)
          return [value, 0, 1] if value.encoding.to_s == 'ASCII-8BIT' && !value.ascii_only?

          [value, 0, 0]
        end

        def decode(cell, type)
          return cell.force_encoding('UTF-8') if type == Native::T_TEXT
          return cell.to_i if type == Native::T_INT
          return %w[t 1].include?(cell) if type == Native::T_BOOL
          return float_value(cell) if type == Native::T_FLOAT
          return decimal_value(cell) if type == Native::T_DECIMAL
          return unsigned_value(cell) if type == Native::T_UINT

          cell
        end

        def float_value(cell)
          return 0.0 / 0.0 if cell == 'NaN'
          return 1.0 / 0.0 if %w[Infinity inf].include?(cell)
          return -1.0 / 0.0 if ['-Infinity', '-inf'].include?(cell)

          cell.to_f
        end

        def decimal_value(cell)
          return cell.force_encoding('UTF-8') if ['NaN', 'Infinity', '-Infinity'].include?(cell)

          ExactDecimal.parse(cell)
        end

        def unsigned_value(cell)
          return cell.to_i if cell.length < 19
          return cell.to_i if cell.length == 19 && cell <= I64_MAX_TEXT

          UInt64Value.parse(cell.force_encoding('UTF-8'))
        end

        def row(raw, lens, types, width)
          values = []
          offset = 0
          col = 0
          while col < width
            len = lens[col]
            values << (len.negative? ? nil : decode(raw.byteslice(offset, len), types[col]))
            offset += len unless len.negative?
            col += 1
          end
          values
        end
      end
    end
  end
end
