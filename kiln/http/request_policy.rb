module Kiln
  module HTTP
    module RequestPolicy
      class << self
        def head_problem(version, verb, target, headers)
          return :not_implemented if verb == 'CONNECT'
          return :bad unless target_shape?(verb, target)

          host_problem(version, headers['host'], absolute_form?(target))
        end

        def target_shape?(verb, target)
          return verb == 'OPTIONS' if target == '*'

          target.start_with?('/') || absolute_form?(target)
        end

        def absolute_form?(target)
          !target.start_with?('/') && target.match?(Syntax::ABSOLUTE_FORM)
        end

        def host_problem(version, host, absolute)
          return :bad if version == '1.1' && (host.nil? || (!absolute && host.empty?))
          return :bad if host && !host.empty? && !Native.host?(host)

          nil
        end

        def origin(target, headers)
          return target unless absolute_form?(target)

          path, authority = Syntax.absolute_target(target)
          headers['host'] = authority if path
          path
        end

        def framing_problem(version, headers)
          return :bad if headers.key?('transfer-encoding') && (version == '1.0' || headers.key?('content-length'))

          expect = headers['expect']
          return :expectation if expect && !expect.empty? && expect.strip.downcase != '100-continue'

          nil
        end

        def chunked_problem(coding)
          codings = coding.split(',', -1).map { |item| item.strip.downcase }
          return :bad if codings.any?(&:empty?) || codings.last != 'chunked' || codings.count('chunked') > 1
          return :unsupported_te if codings.size > 1

          nil
        end

        def continue?(headers, version)
          version == '1.1' && Syntax.token_list?(headers['expect'], '100-continue')
        end
      end
    end
  end
end
