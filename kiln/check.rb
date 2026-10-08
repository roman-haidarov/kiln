module Kiln
  module Check
    def check_rules(rows)
      index = 0
      while index < rows.size
        name, value, kind = rows[index]
        raise ArgumentError, name unless rule?(kind, value)

        index += 1
      end
    end

    def rule?(kind, value)
      integer = value.is_a?(Integer)
      return false unless integer || (value.is_a?(Float) && value.finite?)

      negative = value.negative?
      case kind
      when :int_at_least_one
        integer && value >= 1
      when :int_at_least_zero
        integer && value >= 0
      when :int_from_minus_one
        integer && value >= -1
      when :seconds_above
        value.positive?
      when :seconds_at_least
        !negative
      when :await_timeout
        negative ? value == -1 : true
      else
        false
      end
    end
    private :check_rules, :rule?
  end
end
