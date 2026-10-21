module Kiln
  module HTTP
    class BadRequest < StandardError; end
    class UnsupportedMediaType < StandardError; end
    class PayloadTooLarge < StandardError; end
    class RequestTimeout < StandardError; end
    class TrailersTooLarge < StandardError; end
    class JsonError < StandardError; end
    class JsonGenerateError < StandardError; end
  end
end
