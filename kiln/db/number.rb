module Kiln
  module DB
    module Words
      def /(other) = divmod(other)[0]
      def %(other) = divmod(other)[1]
      def <(other) = (self <=> other).negative?
      def <=(other) = (self <=> other) <= 0
      def >(other) = (self <=> other).positive?
      def >=(other) = (self <=> other) >= 0
      def eql?(other) = other.is_a?(self.class) && @hi == other.hi && @lo == other.lo
      def hash = [@hi, @lo].hash
      def bind_text = to_s
      def to_decimal = ExactDecimal.parse(to_s)

      def self.check_parse(status, kind)
        raise ArgumentError, "#{kind} text" if status == Native::CONFIG
        raise RangeError, "#{kind} range" unless status == Native::OK
      end

      def self.check_apply(status, kind)
        raise RangeError, "#{kind} op" if status == Native::ERR
        raise ArgumentError, "#{kind} op" unless status == Native::OK
      end

      private

      def word_order(other)
        return @hi <=> other.hi unless @hi == other.hi

        @lo <=> other.lo
      end
    end

    class Int64Value
      include Words

      attr_reader :hi, :lo

      def initialize(high, low)
        raise RangeError, 'int64 hi' unless high.is_a?(Integer) && high >= -2_147_483_648 && high <= 2_147_483_647
        raise RangeError, 'int64 lo' unless low.is_a?(Integer) && low >= 0 && low <= 4_294_967_295

        @hi = high
        @lo = low
      end

      class << self
        def parse(text)
          raise ArgumentError, 'int64 text' unless text.is_a?(String) && text.length.positive?

          words = [0, 0]
          rc = Native.kiln_db_i64_parse(text, words, 2)
          Words.check_parse(rc, 'int64')
          new(words[0], words[1])
        end

        def min_value
          new(-2_147_483_648, 0)
        end

        def max_value
          new(2_147_483_647, 4_294_967_295)
        end

        def apply(operation, left, right)
          out = [0, 0, 0, 0]
          rc = Native.kiln_db_i64_apply(operation, left.hi, left.lo, right.hi, right.lo, out, 4)
          Words.check_apply(rc, 'int64')
          [new(out[0], out[1]), new(out[2], out[3])]
        end

        def integer_text(value)
          value.to_s
        end

        def from_i(value)
          text = integer_text(value)
          raise TypeError, 'int64 nil' if text.empty?
          raise TypeError, 'int64 type' unless value.is_a?(Integer)

          parse(text)
        end
      end

      def min_value?
        @hi == -2_147_483_648 && @lo.zero?
      end

      def -@
        parts = Int64Value.apply(Native::NUM_NEG, self, Int64Value.new(0, 0))
        parts[0]
      end

      def +(other)
        Int64Value.apply(Native::NUM_ADD, self, coerce(other))[0]
      end

      def -(other)
        Int64Value.apply(Native::NUM_SUB, self, coerce(other))[0]
      end

      def *(other)
        Int64Value.apply(Native::NUM_MUL, self, coerce(other))[0]
      end

      def divmod(other)
        rhs = coerce(other)
        raise ZeroDivisionError, 'divide by zero' if rhs.hi.zero? && rhs.lo.zero?
        raise RangeError, 'int64 div' if min_value? && rhs.hi == -1 && rhs.lo == 4_294_967_295

        Int64Value.apply(Native::NUM_DIV, self, rhs)
      end

      def <=>(other)
        return word_order(other) if other.is_a?(Int64Value)

        text = other.to_s
        raise TypeError, 'int64 cmp' if text.empty? || !other.is_a?(Integer)

        out = [0]
        rc = Native.kiln_db_i64_cmp_text(@hi, @lo, text, out, 1)
        raise ArgumentError, 'int64 cmp' if rc != Native::OK

        out[0]
      end

      def ==(other)
        return @hi == other.hi && @lo == other.lo if other.is_a?(Int64Value)
        return false unless other.is_a?(Integer)

        (self <=> other).zero?
      end

      def to_i
        raise RangeError, 'int64 to_i' if min_value?

        to_s.to_i
      end

      def to_s
        Native.kiln_db_i64_text(@hi, @lo)
      end

      def coerce(other)
        return other if other.is_a?(Int64Value)
        raise TypeError, 'int64 type' if other.nil? || !other.is_a?(Integer)

        Int64Value.from_i(other)
      end
    end

    class UInt64Value
      include Words

      attr_reader :hi, :lo

      def initialize(high, low)
        raise RangeError, 'uint64 hi' unless high.is_a?(Integer) && high >= 0 && high <= 4_294_967_295
        raise RangeError, 'uint64 lo' unless low.is_a?(Integer) && low >= 0 && low <= 4_294_967_295

        @hi = high
        @lo = low
      end

      class << self
        def parse(text)
          raise ArgumentError, 'uint64 text' unless text.is_a?(String) && text.length.positive?

          words = [0, 0]
          rc = Native.kiln_db_u64_parse(text, words, 2)
          Words.check_parse(rc, 'uint64')
          new(words[0], words[1])
        end

        def max_value
          new(4_294_967_295, 4_294_967_295)
        end

        def apply(operation, left, right)
          out = [0, 0, 0, 0]
          rc = Native.kiln_db_u64_apply(operation, left.hi, left.lo, right.hi, right.lo, out, 4)
          Words.check_apply(rc, 'uint64')
          [new(out[0], out[1]), new(out[2], out[3])]
        end

        def integer_text(value)
          value.to_s
        end

        def cmp_saved(high, low, text)
          out = [0]
          rc = Native.kiln_db_u64_cmp_text(high, low, text, out, 1)
          raise ArgumentError, 'uint64 cmp' if rc != Native::OK

          out[0]
        end

        def from_i(value)
          text = integer_text(value)
          raise TypeError, 'uint64 nil' if text.empty?
          raise TypeError, 'uint64 type' unless value.is_a?(Integer)
          raise RangeError, 'uint64 range' if text[0] == '-'

          parse(text)
        end
      end

      def +(other)
        UInt64Value.apply(Native::NUM_ADD, self, coerce(other))[0]
      end

      def -(other)
        UInt64Value.apply(Native::NUM_SUB, self, coerce(other))[0]
      end

      def *(other)
        UInt64Value.apply(Native::NUM_MUL, self, coerce(other))[0]
      end

      def divmod(other)
        rhs = coerce(other)
        raise ZeroDivisionError, 'divide by zero' if rhs.hi.zero? && rhs.lo.zero?

        UInt64Value.apply(Native::NUM_DIV, self, rhs)
      end

      def <=>(other)
        return word_order(other) if other.is_a?(UInt64Value)

        text = other.to_s
        raise TypeError, 'uint64 cmp' if text.empty? || !other.is_a?(Integer)

        UInt64Value.cmp_saved(@hi, @lo, text)
      end

      def ==(other)
        return @hi == other.hi && @lo == other.lo if other.is_a?(UInt64Value)

        text = other.to_s
        return false unless other.is_a?(Integer)
        return false if text.empty?

        UInt64Value.cmp_saved(@hi, @lo, text).zero?
      end

      def to_i
        raise RangeError, 'uint64 to_i' if @hi > 2_147_483_647

        to_s.to_i
      end

      def to_s
        Native.kiln_db_u64_text(@hi, @lo)
      end

      def coerce(other)
        return other if other.is_a?(UInt64Value)
        raise TypeError, 'uint64 type' if other.nil? || !other.is_a?(Integer)

        UInt64Value.from_i(other)
      end
    end

    class ExactDecimal
      DIGITS = /\A[0-9]+\z/
      JUNK = /[^0-9.]/

      attr_reader :sign, :digits, :scale

      def initialize(sign, digits, scale)
        raise ArgumentError, 'decimal sign' unless [-1, 0, 1].include?(sign)
        raise ArgumentError, 'decimal digits' unless digits.is_a?(String) && DIGITS.match?(digits)
        raise ArgumentError, 'decimal scale' unless scale.is_a?(Integer) && scale >= 0

        @sign = digits == '0' ? 0 : sign
        @digits = digits
        @scale = scale
      end

      class << self
        def parse(text)
          raise ArgumentError, 'decimal text' unless text.is_a?(String) && text.length.positive?

          sign, body = split_sign(text)
          raise ArgumentError, 'decimal text' if body.empty?

          check_body(body)
          raw = body.delete('.')
          raise ArgumentError, 'decimal digits' if raw.empty?

          new(sign, strip_leading(raw), scale_of(body))
        end

        def from_i(value)
          raise TypeError, 'decimal nil' if value.nil?
          raise TypeError, 'decimal type' unless value.is_a?(Integer)

          parse(value.to_s)
        end

        def strip_leading(raw)
          i = 0
          i += 1 while i < raw.length - 1 && raw[i] == '0'
          raw[i, raw.length - i]
        end

        private

        def split_sign(text)
          lead = text[0]
          return [1, text] unless %w[- +].include?(lead)

          [lead == '-' ? -1 : 1, text[1, text.length - 1]]
        end

        def scale_of(body)
          dot = body.index('.')
          dot ? body.length - dot - 1 : 0
        end

        def check_body(body)
          first_dot = body.index('.')
          second_dot = first_dot && body.index('.', first_dot + 1)
          junk = body.index(JUNK)
          raise ArgumentError, 'decimal dot' if second_dot && (junk.nil? || second_dot < junk)
          raise ArgumentError, 'decimal digits' if junk
        end
      end

      def to_s
        body = String.new
        body << plain_digits
        return body if @sign >= 0

        out = String.new
        out << '-' << body
        out
      end

      def bind_text = to_s
      def ==(other) = other.is_a?(ExactDecimal) && canonical == other.canonical
      def eql?(other) = self == other

      def hash = canonical.hash

      def <=>(other)
        raise TypeError, 'decimal cmp' unless other.is_a?(ExactDecimal)
        return 0 if self == other
        return (@sign.zero? ? -other.sign : @sign) if @sign.zero? || other.sign.zero? || @sign != other.sign

        digit_order(other)
      end

      def canonical
        d = @digits
        sc = @scale
        while sc.positive? && d[-1] == '0'
          d = d[0, d.length - 1]
          d = '0' if d.empty?
          sc -= 1
        end
        sign = d == '0' ? 0 : @sign
        [sign, d, sc]
      end

      def align(target)
        extra = target - @scale
        d = extra.positive? ? "#{@digits}#{'0' * extra}" : @digits
        [d == '0' ? 0 : @sign, d]
      end

      private

      def plain_digits
        return @digits.dup if @scale.zero?
        return "0.#{'0' * (@scale - @digits.length)}#{@digits}" if @digits.length <= @scale

        cut = @digits.length - @scale
        "#{@digits[0, cut]}.#{@digits[cut, @scale]}"
      end

      def digit_order(other)
        scale = [@scale, other.scale].max
        left = align(scale)[1]
        right = other.align(scale)[1]
        cmp = left.length == right.length ? left <=> right : left.length <=> right.length
        @sign.negative? ? -cmp : cmp
      end
    end
  end
end
