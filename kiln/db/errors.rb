module Kiln
  module DB
    class Error < StandardError
      attr_reader :sqlstate, :code

      def initialize(message = nil, sqlstate: nil, code: nil)
        super(message)
        @sqlstate = sqlstate
        @code = code
      end
    end

    class ConfigError < Error; end
    class ConnectionError < Error; end
    class Timeout < Error; end
    class NotFound < Error; end
    class NotLoaded < Error; end
    class StaleView < Error; end
    class OwnershipError < Error; end
    class CapacityError < Error; end
    class InvalidatedRecord < Error; end
    class RecordInvalid < Error; end
    class UniqueViolation < Error; end
    class ForeignKeyViolation < Error; end
    class NotNullViolation < Error; end
    class CheckViolation < Error; end
    class Deadlock < Error; end
    class SerializationFailure < Error; end
    class LockWaitTimeout < Error; end
    class Unsupported < Error; end
    class UnsafeImportSchema < Error; end
    class UnsupportedReturn < Error; end
    class UnsupportedExactStatus < Error; end
    class AmbiguousConflict < Error; end
    class NonDeterministicQuery < Error; end
    class UnknownRootIdentity < Error; end
    class UnknownCommitOutcome < Error; end
    class PoisonedTransaction < Error; end

    class PostCommitCallbackError < Error
      attr_reader :state, :result

      def initialize(message = nil, result: nil, sqlstate: nil, code: nil)
        super(message, sqlstate: sqlstate, code: code)
        @state = 'COMMITTED'
        @result = result
      end
    end

    class InvariantViolation < Error; end

    module Errors
      class << self
        def code_of(name)
          case name
          when 'UnsafeImportSchema'
            7
          when 'UnsupportedReturn', 'UnsupportedExactStatus', 'AmbiguousConflict',
               'NonDeterministicQuery', 'UnknownRootIdentity', 'Unsupported'
            6
          end
        end
      end
    end
  end
end
