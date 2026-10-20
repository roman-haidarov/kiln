require 'kiln'
require 'stringio'
require 'zlib'
require 'tmpdir'
require 'test/support'

def check(label, passed)
  raise "FAIL #{label}" unless passed

  puts "ok   #{label}"
end

def raises(label, klass, fragment)
  yield
  raise "FAIL #{label}: nothing raised"
rescue klass => e
  check(label, e.message.include?(fragment))
end

def gz(app, path, encoding = 'gzip', verb = 'GET')
  headers = encoding ? { 'Accept-Encoding' => encoding } : {}
  Kiln::Testing.call(app, verb, path, headers:)
end

def split_reply(raw)
  cut = raw.index("\r\n\r\n")
  return ['', ''] unless cut

  [raw.byteslice(0, cut), raw.byteslice(cut + 4, raw.bytesize - cut - 4)]
end

def dechunk(data)
  out = (+'').b
  pos = 0
  loop do
    eol = data.index("\r\n", pos)
    return out unless eol

    size = data.byteslice(pos, eol - pos).to_i(16)
    return out if size.zero?

    out << data.byteslice(eol + 2, size)
    pos = eol + 2 + size + 2
  end
end

TEXT = ('kiln compresses text responses; ' * 200).freeze
EVENTS = Queue.new
RELEASE = Queue.new

def build_app
  router = Kiln::Router.new
  router.get('/text', ->(ctx) { ctx.res.text(TEXT) })
  router.get('/tiny', ->(ctx) { ctx.res.text('tiny') })
  items = Array.new(200) { |i| { 'id' => i, 'name' => "item #{i}" } }
  router.get('/json', ->(ctx) { ctx.res.json_value({ 'items' => items }) })
  router.get('/png', lambda do |ctx|
    ctx.res.headers['Content-Type'] = 'image/png'
    ctx.res.body = TEXT
  end)
  router.get('/encoded', lambda do |ctx|
    ctx.res.text(TEXT)
    ctx.res.headers['Content-Encoding'] = 'br'
  end)
  router.get('/notransform', lambda do |ctx|
    ctx.res.text(TEXT)
    ctx.res.headers['Cache-Control'] = 'no-transform'
  end)
  router.get('/twocache', lambda do |ctx|
    ctx.res.text(TEXT)
    ctx.res.headers['Cache-Control'] = 'public'
    ctx.res.headers.add('Cache-Control', 'no-transform')
  end)
  router.get('/reset', lambda do |ctx|
    ctx.res.headers['Content-Type'] = 'text/plain'
    ctx.res.status = 205
    ctx.res.body = TEXT
  end)
  router.get('/app304', lambda do |ctx|
    ctx.res.status = 304
    ctx.res.headers['ETag'] = '"app"'
    ctx.res.headers['Content-Type'] = 'text/plain'
    ctx.res.body = ''
  end)
  router.get('/tagged', lambda do |ctx|
    ctx.res.text(TEXT)
    ctx.res.headers['ETag'] = '"v1"'
    ctx.res.headers['Accept-Ranges'] = 'bytes'
  end)
  router.get('/empty', ->(ctx) { ctx.res.status = 204 })
  router.get('/stream', lambda do |ctx|
    ctx.res.stream(type: 'text/plain', length: TEXT.bytesize) { |out| out.write(TEXT) }
  end)
  router.get('/ticks', lambda do |ctx|
    ctx.res.sse do |out|
      out.event('first', event: 'tick')
      EVENTS << :sent
      RELEASE.pop(timeout: 5)
      out.event('second', event: 'tick')
    end
  end)
  Kiln::Compress.new(router.seal!, min_size: 512)
end

puts '-- negotiation'
check 'plain gzip', Kiln::Compress.accepts_gzip?('gzip')
check 'list with q', Kiln::Compress.accepts_gzip?('br;q=1.0, gzip;q=0.8, *;q=0.1')
check 'gzip refused with q=0', !Kiln::Compress.accepts_gzip?('gzip;q=0, deflate')
check 'x-gzip alias', Kiln::Compress.accepts_gzip?('x-gzip')
check 'star allows gzip', Kiln::Compress.accepts_gzip?('*')
check 'explicit gzip;q=0 beats star', !Kiln::Compress.accepts_gzip?('*, gzip;q=0')
check 'identity only', !Kiln::Compress.accepts_gzip?('identity') && !Kiln::Compress.accepts_gzip?(nil)
check 'case and spaces', Kiln::Compress.accepts_gzip?(' GZip ; Q=0.5 ')
check 'q outside 0..1 is ignored', !Kiln::Compress.accepts_gzip?('gzip;q=2')
check 'q without a value is ignored', !Kiln::Compress.accepts_gzip?('gzip;q')
check 'an invalid gzip q leaves the star', Kiln::Compress.accepts_gzip?('*;q=0.1, gzip;q=2')
check 'q accepts an empty fractional part', Kiln::Compress.accepts_gzip?('gzip;q=1.')
check 'q accepts three decimal places', Kiln::Compress.accepts_gzip?('gzip;q=1.000')
check 'q rejects more than three decimal places', !Kiln::Compress.accepts_gzip?('gzip;q=1.0000')
check 'the last valid q parameter wins', Kiln::Compress.accepts_gzip?('gzip;q=0;q=1')
raises('levels are validated', ArgumentError, 'levels') { Kiln::Compress.new(->(_ctx) {}, level: 0) }

failed_handle = Kiln::Gzip.open_handle(1)
Kiln::Gzip.push(failed_handle, 'finished', 2)
raises('a completed gzip stream cannot be written again', Kiln::CompressError, 'gzip stream finished') do
  Kiln::Gzip.push(failed_handle, 'unexpected', 0)
end
raises('a failed gzip stream cannot resume', Kiln::CompressError, 'gzip stream failed') do
  Kiln::Gzip.push(failed_handle, 'unexpected', 0)
end
Kiln::Gzip.close_handle(failed_handle)
first_handle = Kiln::Gzip.open_handle(1)
second_handle = Kiln::Gzip.open_handle(1)
check 'a failed gzip stream cannot enter the pool twice', first_handle != second_handle
Kiln::Gzip.close_handle(first_handle)
Kiln::Gzip.close_handle(second_handle)
reused_handle = Kiln::Gzip.open_handle(1)
reused = Kiln::Gzip.push(reused_handle, 'pool reuse', 2)
check 'a pooled finished gzip stream resets before reuse', Zlib.gunzip(reused) == 'pool reuse'
Kiln::Gzip.close_handle(reused_handle)
empty_handle = Kiln::Gzip.open_handle(1)
empty_start = Kiln::Gzip.push(empty_handle, '', 0)
empty_flush = Kiln::Gzip.push(empty_handle, '', 1)
empty_end = Kiln::Gzip.push(empty_handle, 'after flush', 2)
check 'an empty gzip write and flush do not fail',
      Zlib.gunzip(empty_start + empty_flush + empty_end) == 'after flush'
Kiln::Gzip.close_handle(empty_handle)

puts '-- bodies'
app = build_app
packed = gz(app, '/text')
check 'text is gzipped', packed.headers['Content-Encoding'] == 'gzip' && packed.body.bytesize < TEXT.bytesize / 10
check 'gzip round-trips through another inflater', Zlib.gunzip(packed.body) == TEXT
check 'Vary is set', packed.headers['Vary'] == 'Accept-Encoding'
json = gz(app, '/json')
check 'json is gzipped', json.headers['Content-Encoding'] == 'gzip' && Zlib.gunzip(json.body).start_with?('{"items":[')
plain = gz(app, '/text', nil)
check 'no Accept-Encoding: identity with Vary',
      plain.headers['Content-Encoding'].nil? && plain.body == TEXT && plain.headers['Vary'] == 'Accept-Encoding'
check 'q=0 is respected', gz(app, '/text', 'gzip;q=0').headers['Content-Encoding'].nil?
tiny = gz(app, '/tiny')
check 'small bodies stay as they are, without Vary',
      tiny.body == 'tiny' && tiny.headers['Content-Encoding'].nil? && tiny.headers['Vary'].nil?
check 'images are not recompressed', gz(app, '/png').headers['Content-Encoding'].nil?
check 'an existing Content-Encoding is kept', gz(app, '/encoded').headers['Content-Encoding'] == 'br'
check 'no-transform is honoured', gz(app, '/notransform').headers['Content-Encoding'].nil?
two = gz(app, '/twocache')
check 'a second Cache-Control no-transform is honoured',
      two.headers['Content-Encoding'].nil? && two.body == TEXT && two.headers['Vary'].nil?
reset = gz(app, '/reset')
check '205 is not encoded',
      reset.status == 205 && reset.body == TEXT && reset.headers['Content-Encoding'].nil? && reset.headers['Vary'].nil?
app304 = gz(app, '/app304')
check 'an application 304 without a length is left unchanged',
      app304.status == 304 && app304.headers['ETag'] == '"app"' && app304.headers['Vary'].nil? &&
      app304.headers['Content-Encoding'].nil?
check '204 is untouched', gz(app, '/empty').status == 204 && gz(app, '/empty').headers['Content-Encoding'].nil?
tagged = gz(app, '/tagged')
check 'strong ETag becomes weak', tagged.headers['ETag'] == 'W/"v1"'
check 'Accept-Ranges is dropped', tagged.headers['Accept-Ranges'].nil?
head = gz(app, '/text', 'gzip', 'HEAD')
check 'HEAD carries the same encoding', head.headers['Content-Encoding'] == 'gzip'

class RaisingBody
  def to_s
    raise 'boom'
  end
end
boom_router = Kiln::Router.new
boom_router.get('/boom', lambda do |ctx|
  ctx.res.headers['Content-Type'] = 'text/plain'
  ctx.res.body = RaisingBody.new
end)
boom_log = Kiln::Log.new(StringIO.new)
guarded = Kiln::Rescue.new(Kiln::Compress.new(boom_router.seal!, min_size: 1), boom_log)
failed = gz(guarded, '/boom')
check 'a body that raises is a plain 500',
      failed.status == 500 && failed.body == "internal error\n" &&
      failed.headers['Content-Encoding'].nil? && failed.headers['Vary'].nil?
boom_log.close

puts '-- streams'
sized = gz(app, '/stream')
check 'a sized stream loses its length and is gzipped',
      sized.headers['Content-Encoding'] == 'gzip' && Zlib.gunzip(sized.body) == TEXT
RELEASE << :go
ticks = gz(app, '/ticks')
EVENTS.pop
check 'SSE is gzipped', Zlib.gunzip(ticks.body) == "event: tick\ndata: first\n\nevent: tick\ndata: second\n\n"

puts '-- files'
root = Dir.mktmpdir('kiln-gzip')
File.write(File.join(root, 'page.html'), TEXT)
File.write(File.join(root, 'small.txt'), 'tiny')
files = Kiln::Router.new.get('/f/*path', Kiln::Static.new(root)).seal!
assets = Kiln::Compress.new(files)
page = gz(assets, '/f/page.html')
check 'a static file is gzipped with a weak ETag',
      page.headers['Content-Encoding'] == 'gzip' && page.headers['ETag'].start_with?('W/"') &&
      Zlib.gunzip(page.body) == TEXT
range_headers = { 'Accept-Encoding' => 'gzip', 'Range' => 'bytes=0-9' }
ranged = Kiln::Testing.call(assets, 'GET', '/f/page.html', headers: range_headers)
check 'a 206 range is not gzipped',
      ranged.status == 206 && ranged.headers['Content-Encoding'].nil? && ranged.body == TEXT.byteslice(0, 10)
weak = page.headers['ETag']
fresh = Kiln::Testing.call(assets, 'GET', '/f/page.html',
                           headers: { 'Accept-Encoding' => 'gzip', 'If-None-Match' => weak })
check 'a compressed file revalidates with the weak ETag',
      fresh.status == 304 && fresh.body.empty? && fresh.headers['ETag'] == weak &&
      fresh.headers['Vary'] == 'Accept-Encoding' && fresh.headers['Accept-Ranges'].nil? &&
      fresh.headers['Content-Encoding'].nil?
plain_page = gz(assets, '/f/page.html', nil)
plain_tag = plain_page.headers['ETag']
plain_fresh = Kiln::Testing.call(assets, 'GET', '/f/page.html', headers: { 'If-None-Match' => plain_tag })
check 'an identity revalidation keeps the strong ETag and Vary',
      plain_page.headers['Content-Encoding'].nil? && plain_page.headers['Vary'] == 'Accept-Encoding' &&
      plain_tag.start_with?('"') && plain_fresh.status == 304 && plain_fresh.headers['ETag'] == plain_tag &&
      plain_fresh.headers['Vary'] == 'Accept-Encoding' && plain_fresh.headers['Accept-Ranges'] == 'bytes' &&
      plain_fresh.headers['Content-Encoding'].nil?
small = gz(assets, '/f/small.txt')
small_tag = small.headers['ETag']
small_fresh = Kiln::Testing.call(assets, 'GET', '/f/small.txt',
                                 headers: { 'Accept-Encoding' => 'gzip', 'If-None-Match' => small_tag })
check 'a small static file is not compressed',
      small.body == 'tiny' && small.headers['Content-Encoding'].nil? && small.headers['Vary'].nil? &&
      small_tag.start_with?('"')
check 'a small file revalidates with its strong ETag',
      small_fresh.status == 304 && small_fresh.headers['ETag'] == small_tag && small_fresh.headers['Vary'].nil? &&
      small_fresh.headers['Accept-Ranges'] == 'bytes' && small_fresh.headers['Content-Encoding'].nil?
strong = weak.delete_prefix('W/')
blocked = Kiln::Testing.call(assets, 'GET', '/f/page.html',
                             headers: { 'Accept-Encoding' => 'gzip', 'If-Match' => strong })
check 'If-Match of the uncompressed tag is 412',
      blocked.status == 412 && blocked.body.empty? && blocked.headers['Content-Encoding'].nil?
starred = Kiln::Testing.call(assets, 'GET', '/f/page.html',
                             headers: { 'Accept-Encoding' => 'gzip', 'If-Match' => '*' })
check 'If-Match star still compresses',
      starred.status == 200 && starred.headers['Content-Encoding'] == 'gzip' && starred.headers['ETag'] == weak

mutations = 0
updates = Kiln::Router.new
updates.post('/update', lambda do |ctx|
  mutations += 1
  ctx.res.text(TEXT)
  ctx.res.headers['ETag'] = '"identity"'
end)
updated = Kiln::Testing.call(Kiln::Compress.new(updates.seal!), 'POST', '/update',
                             headers: { 'Accept-Encoding' => 'gzip', 'If-Match' => '"identity"' })
check 'a conditional POST is not rejected after its handler has run',
      mutations == 1 && updated.status == 200 && updated.body == TEXT &&
      updated.headers['ETag'] == '"identity"' && updated.headers['Content-Encoding'].nil?

log = Kiln::Log.new(StringIO.new)
[[:event, 0], [:event, 2], [:base, 0]].each do |backend, handlers|
  name = backend == :event ? "event/#{handlers}" : 'base'
  options = { log:, port: 0, host: '127.0.0.1', backend: }
  options[:handlers] = handlers if backend == :event
  server = Kiln::Server.new(build_app, nil, **options)
  server.start
  port = server.port
  sock = TCPSocket.new('127.0.0.1', port)
  sock.write("GET /text HTTP/1.1\r\nHost: t\r\nAccept-Encoding: gzip\r\nConnection: close\r\n\r\n")
  head_text, body = split_reply(read_until_closed(sock, 3).b)
  sock.close
  check "#{name}: gzip over the wire", head_text.include?('Content-Encoding: gzip') && Zlib.gunzip(body) == TEXT

  sock = TCPSocket.new('127.0.0.1', port)
  sock.write("GET /ticks HTTP/1.1\r\nHost: t\r\nAccept-Encoding: gzip\r\nConnection: close\r\n\r\n")
  EVENTS.pop(timeout: 3)
  early = (+'').b
  limit = Kiln.now + 2.0
  until (early.include?("\r\n\r\n") && early.bytesize > early.index("\r\n\r\n") + 20) || Kiln.now > limit
    ready = IO.select([sock], nil, nil, 0.1)
    early << sock.readpartial(4096) if ready
  end
  check "#{name}: the first gzipped event arrives before the stream ends",
        early.bytesize > early.index("\r\n\r\n").to_i + 20
  RELEASE << :go
  rest = read_until_closed(sock, 3).b
  sock.close
  _, wire = split_reply(early + rest)
  check "#{name}: the whole SSE stream inflates", Zlib.gunzip(dechunk(wire)).end_with?("data: second\n\n")
  server.shutdown(grace: 1.0)
end
log.close
puts 'done'
