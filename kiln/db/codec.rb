module Kiln
  module DB
    class RowBatch
      attr_reader :raw, :lens, :nums, :floats

      def initialize(lens, size)
        @raw = ''.b
        @lens = lens
        @nums = Array.new(size, 0)
        @floats = Array.new(size, 0.0)
      end

      def load(raw, lens)
        @raw = raw
        @lens = lens
        self
      end
    end

    module Codec
      I64_MAX_TEXT = '9223372036854775807'.freeze
      NUL = "\0".freeze
      BACKSLASH = '\\'.freeze

      class << self
        def encode(dialect, value)
          return [nil, 1, 0] if value.nil?
          return [bool_text(dialect, value), 0, 0] if [true, false].include?(value)
          return string_param(dialect, value) if value.is_a?(String)

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

        def string_param(dialect, value)
          return [value, 0, 1] if binary_text?(value)
          raise ArgumentError, 'bind String: NUL byte in text' if dialect == :postgres && value.include?(NUL)

          [value, 0, 0]
        end

        def binary_text?(value)
          return false unless value.is_a?(String) && value.encoding.to_s == 'ASCII-8BIT'

          !value.ascii_only? || value.include?(NUL) || value.include?(BACKSLASH)
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
          return cell.to_i if cell.length < I64_MAX_TEXT.length
          return cell.to_i if cell.length == I64_MAX_TEXT.length && cell <= I64_MAX_TEXT

          UInt64Value.parse(cell.force_encoding('UTF-8'))
        end
      end

      module Rows
        INT64_MIN = -9_223_372_036_854_775_807 - 1

        def rows_into(out, batch, types, count)
          lens = batch.lens
          stride = types.length + 1
          offset = 0
          at = 0
          while at < count * stride
            out << row_values(batch, at, offset, types)
            offset += lens[at + stride - 1]
            at += stride
          end
          out
        end

        def column_into(out, batch, types, count)
          lens = batch.lens
          stride = types.length + 1
          offset = 0
          at = 0
          while at < count * stride
            out << cell(batch, lens[at], at, offset, types[0])
            offset += lens[at + stride - 1]
            at += stride
          end
          out
        end

        def row_values(batch, at, offset, types)
          lens = batch.lens
          values = []
          col = 0
          while col < types.length
            len = lens[at + col]
            values << cell(batch, len, at + col, offset, types[col])
            offset += len unless len.negative?
            col += 1
          end
          values
        end

        def cell(batch, len, index, offset, type)
          return typed_cell(batch, len, index, type) if len.negative?

          decode(batch.raw.byteslice(offset, len), type)
        end

        def typed_cell(batch, len, index, type)
          return nil if len == -1
          return batch.floats[index] if len == -4

          number = batch.nums[index]
          return number == 1 if type == Native::T_BOOL

          number.nil? ? INT64_MIN : number
        end

        def text_row(raw, lens, types)
          values = []
          offset = 0
          col = 0
          while col < types.length
            len = lens[col]
            values << (len.negative? ? nil : decode(raw.byteslice(offset, len), types[col]))
            offset += len unless len.negative?
            col += 1
          end
          values
        end

        def row(raw, lens, types, _width) = text_row(raw, lens, types)
      end

      extend Rows
    end
  end
end
