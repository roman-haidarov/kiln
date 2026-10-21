module Kiln
  module Runtime
    module Check
      INTEGER_FLOORS = { int_at_least_one: 1, int_at_least_zero: 0, int_from_minus_one: -1 }.freeze

      def check_rules(rows)
        index = 0
        while index < rows.size
          name, value, kind = rows[index]
          raise ArgumentError, name unless rule?(kind, value)

          index += 1
        end
      end

      def rule?(kind, value)
        return false unless finite_number?(value)

        floor = INTEGER_FLOORS[kind]
        return value.is_a?(Integer) && value >= floor unless floor.nil?

        seconds_rule?(kind, value)
      end

      def finite_number?(value)
        value.is_a?(Integer) || (value.is_a?(Float) && value.finite?)
      end

      def seconds_rule?(kind, value)
        case kind
        when :seconds_above then value.positive?
        when :seconds_at_least then !value.negative?
        when :await_timeout then !value.negative? || value == -1
        else false
        end
      end
      private :check_rules, :rule?, :finite_number?, :seconds_rule?
    end
  end
end
