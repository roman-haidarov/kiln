require 'kiln'

def now = Kiln::Runtime.now

def per(label, total, count)
  print label
  print ' '
  print((total / count * 1e9).round)
  print " ns\n"
end

n = 200_000
src = "GET /svc/items/42?x=1 HTTP/1.1\r\nHost: example.com\r\nUser-Agent: bench\r\n" \
      "Accept: */*\r\nConnection: keep-alive\r\n\r\nGET".b
head_len = src.index("\r\n\r\n")
out = Kiln::HTTP::Native.scratch
cap = Kiln::HTTP::Native::CAP
hello = ->(ctx) { ctx.res.text("Hello, World!\n") }
router = Kiln::Routing::Router.new.get('/svc/items/:id', hello).seal!

t = now
i = 0
while i < n
  Kiln::HTTP::Native.kiln_http_scan_at(src, src.bytesize, 0, head_len, out, cap)
  i += 1
end
per('c_scan', now - t, n)

count = Kiln::HTTP::Native.kiln_http_scan_at(src, src.bytesize, 0, head_len, out, cap)
t = now
i = 0
while i < n
  Kiln::HTTP::Native.build(src, count, out)
  i += 1
end
per('ruby_build_headers', now - t, n)

parsed = Kiln::HTTP::Native.build(src, count, out)
version = parsed[0]
verb = parsed[1]
target = parsed[2]
headers = parsed[3]
empty = ''.b
deadline = Kiln::Runtime.now + 3600.0
t = now
i = 0
while i < n
  req = Kiln::HTTP::Request.new(verb, target, headers, empty, Kiln::HTTP::Request::Wire.new(version, nil, nil))
  Kiln::Routing::Context.new(req, Kiln::HTTP::Response.new, i, deadline)
  i += 1
end
per('request_context_new', now - t, n)

t = now
i = 0
while i < n
  req = Kiln::HTTP::Request.new(verb, target, headers, empty, Kiln::HTTP::Request::Wire.new(version, nil, nil))
  ctx = Kiln::Routing::Context.new(req, Kiln::HTTP::Response.new, i, deadline)
  router.call(ctx)
  i += 1
end
per('request_context_plus_app', now - t, n)

req = Kiln::HTTP::Request.new(verb, target, headers, empty, Kiln::HTTP::Request::Wire.new(version, nil, nil))
ctx = Kiln::Routing::Context.new(req, Kiln::HTTP::Response.new, 1, deadline)
router.call(ctx)
res = ctx.res
t = now
i = 0
while i < n
  payload = Kiln::HTTP::Response.payload(res.status, res.body)
  Kiln::HTTP::Response.build_head(res.status, res.headers, payload.bytesize, true, version: '1.1')
  i += 1
end
per('send_fixed_build_head', now - t, n)

t = now
i = 0
while i < n
  Kiln::HTTP::Syntax.persistent?(version, headers['connection'])
  i += 1
end
per('keep_open_check', now - t, n)

q = Queue.new
job = [ctx, 1, 2]
t = now
i = 0
while i < n
  q << job
  q.empty?
  q.pop
  i += 1
end
per('queue_push_empty_pop', now - t, n)
print "ok http_pump_parts\n"
