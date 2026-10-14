module Kiln
  module Testing
    class << self
      def call(app, verb, target, headers: {}, body: nil, state: nil, timeout: 2.0)
        res = Response.new
        deadline = Kiln.now + timeout
        ctx = Context.new(Request.new(verb, target, lower(headers), body), res, state, 'test', deadline)
        with_deadline(deadline) { serve(app, ctx) }
        collect(res) if Response.streams?(res)
        res
      end

      def json(app, verb, target, value, headers: {}, state: nil, timeout: 2.0)
        heads = lower(headers)
        heads['content-type'] = Media::JSON_TYPE unless heads.key?('content-type')
        call(app, verb, target, headers: heads, body: Json.generate(value), state:, timeout:)
      end

      private

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
        out = Stream.new(->(_prefix, bytes) { buffer << bytes }, -> { false }, false, res.stream_length)
        res.stream_body.call(out)
        out.flush
        out.verify!
        res.body = buffer
      end

      def serve(app, ctx)
        app.call(ctx)
      rescue Exception => e
        reply = Kiln.timeout_reply(e)
        raise unless reply

        ctx.res.text(reply[0], status: reply[1])
      end

      def lower(headers)
        out = {}
        headers.each { |name, value| out[name.to_s.downcase] = value.to_s }
        out
      end
    end
  end
end
