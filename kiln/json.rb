module Kiln
  class JsonError < StandardError; end
  class JsonGenerateError < StandardError; end

  module Json
    MAX_NESTING = 100

    native_func :native_parse, %i[string int], :any, 'kiln_json_parse'
    native_func :native_generate, [:any], :string, 'kiln_json_generate'

    class << self
      def parse(text, max_nesting: MAX_NESTING) = Json.native_parse(text.to_s, max_nesting)

      def generate(value) = Json.native_generate(value)
    end
  end
end
