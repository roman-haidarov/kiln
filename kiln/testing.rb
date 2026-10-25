module Kiln
  module Testing
    class << self
      CALL_KEYS = %i[headers body timeout].freeze
      JSON_KEYS = %i[headers timeout].freeze

      def call(app, verb, target, **options)
        check_options(options, CALL_KEYS)
        res = HTTP::Response.new
        deadline = Kiln::Runtime.now + options.fetch(:timeout, 2.0)
        ctx = build_context(verb, target, options, res, deadline)
        with_deadline(deadline) { serve(app, ctx) }
        collect(res) if HTTP::Response.streams?(res)
        res
      end

      def json(app, verb, target, value, **options)
        check_options(options, JSON_KEYS)
        heads = lower(options.fetch(:headers) { {} })
        heads['content-type'] = HTTP::Media::JSON_TYPE unless heads.key?('content-type')
        call(app, verb, target, **options, headers: heads, body: HTTP::Json.generate(value))
      end

      private

      def build_context(verb, target, options, res, deadline)
        headers = lower(options.fetch(:headers) { {} })
        req = HTTP::Request.new(verb, target, headers, options[:body])
        Routing::Context.new(req, res, 'test', deadline)
      end

      def check_options(options, keys)
        unknown = options.keys - keys
        raise ArgumentError, "unknown keyword: #{unknown.first}" unless unknown.empty?
      end

      def with_deadline(deadline)
        current = Thread.current
        saved = current[:kiln_deadline]
        current[:kiln_deadline] = deadline
        yield
      ensure
        current[:kiln_deadline] = saved
      end

      def collect(res)
        buffer = (+'').b
        out = HTTP::Stream.new(->(_prefix, bytes) { buffer << bytes }, -> { false }, false, res.stream_length)
        res.stream_body.call(out)
        out.flush
        out.verify!
        res.body = buffer
      end

      def serve(app, ctx)
        app.call(ctx)
      rescue *Kiln::Runtime::FAILURES => e
        reply = Kiln::Runtime.timeout_reply(e)
        raise unless reply

        Kiln::Runtime.apply_reply(ctx, reply)
      end

      def lower(headers)
        out = {}
        headers.each { |name, value| out[name.to_s.downcase] = value.to_s }
        out
      end
    end
  end
end
