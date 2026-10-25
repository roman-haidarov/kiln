require 'kiln'
require 'zlib'

def now = Kiln::Runtime.now

def next_seed(seed) = ((seed * 1_103_515_245) + 12_345) % 2_147_483_648

def record(seed)
  "{\"id\":#{seed},\"name\":\"user-#{seed % 99_991}\",\"score\":#{seed % 1000},\"tag\":\"t#{seed % 37}\"}\n"
end

def body(size)
  out = (+'').b
  seed = 12_345
  while out.bytesize < size
    seed = next_seed(seed)
    out << record(seed)
  end
  out.byteslice(0, size)
end

def once_ms(text)
  t = now
  Kiln::Middleware::Gzip.once(text, 2)
  ((now - t) * 1000).round(2)
end

def push_ms(handle, piece, mode)
  t = now
  Kiln::Middleware::Gzip.push(handle, piece, mode)
  (now - t) * 1000
end

def worst_push_ms(handle, text, chunk)
  worst = 0.0
  offset = 0
  while offset < text.bytesize
    spent = push_ms(handle, text.byteslice(offset, chunk), 0)
    worst = spent if spent > worst
    offset += chunk
  end
  worst
end

def stream_max_ms(text, chunk)
  handle = Kiln::Middleware::Gzip.open_handle(2)
  worst = worst_push_ms(handle, text, chunk)
  last = push_ms(handle, ''.b, 2)
  Kiln::Middleware::Gzip.close_handle(handle)
  [last, worst].max.round(2)
end

def compress_app(text)
  Kiln::Middleware::Compress.new(->(ctx) { ctx.res.text(text) })
end

def middleware_body(stack)
  headers = { 'host' => 'x', 'accept-encoding' => 'gzip' }
  req = Kiln::HTTP::Request.new('GET', '/', headers, ''.b, Kiln::HTTP::Request::Wire.new('1.1', nil, nil))
  ctx = Kiln::Routing::Context.new(req, Kiln::HTTP::Response.new, 1, now + 3600.0)
  stack.call(ctx)
  ctx.res.body.to_s
end

def allocate_until(stop)
  worst = 0.0
  last = now
  keep = []
  until stop.closed?
    keep = [] if keep.length > 10_000
    keep << "x#{keep.length}"
    worst = [worst, now - last].max
    last = now
  end
  worst
end

def last_body(stack, rounds)
  packed = ''
  k = 0
  while k < rounds
    packed = middleware_body(stack)
    k += 1
  end
  packed
end

def roundtrip(text, packed) = Zlib.gunzip(packed) == text ? 'yes' : 'no'

def report_gap(text, packed, spent, worst)
  print "middleware_gzip size=#{text.bytesize} gz=#{packed.bytesize} call_ms=#{spent.round(2)} "
  print "alloc_thread_max_gap_ms=#{(worst * 1000).round(2)} roundtrip=#{roundtrip(text, packed)}\n"
end

def middleware_alone(stack, text)
  t = now
  packed = last_body(stack, 5)
  spent = (now - t) / 5 * 1000
  print "middleware_gzip_alone size=#{text.bytesize} gz=#{packed.bytesize} call_ms=#{spent.round(2)} "
  print "roundtrip=#{roundtrip(text, packed)}\n"
end

def middleware_gap(stack, text)
  stop = Queue.new
  worker = Thread.new { allocate_until(stop) }
  Kiln::Runtime.pause(0.2)
  t = now
  packed = last_body(stack, 5)
  spent = (now - t) / 5 * 1000
  stop.close
  report_gap(text, packed, spent, worker.value)
end

[1_048_576, 10_485_760].each do |size|
  text = body(size)
  once_ms(text)
  print "gzip_once_ms size=#{size} #{once_ms(text)}\n"
  print "gzip_stream_max_call_ms size=#{size} chunk=65536 #{stream_max_ms(text, 65_536)}\n"
  stack = compress_app(text)
  middleware_alone(stack, text)
  middleware_gap(stack, text)
end
print "ok gzip_call\n"
