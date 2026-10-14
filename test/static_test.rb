require 'kiln'
require 'stringio'
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

STAMP = Time.at(1_000_000_000)
STAMP_TEXT = 'Sun, 09 Sep 2001 01:46:40 GMT'.freeze
BIG_SIZE = 600 * 1024

def put(dir, name, text)
  path = File.join(dir, name)
  File.write(path, text)
  File.utime(STAMP, STAMP, path)
  path
end

def big_bytes
  out = (+'').b
  index = 0
  while out.bytesize < BIG_SIZE
    out << format('%07d|', index)
    index += 1
  end
  out.byteslice(0, BIG_SIZE)
end

def fetch(app, path, headers = {}, verb = 'GET') = Kiln::Testing.call(app, verb, path, headers:)

def split_reply(raw)
  cut = raw.index("\r\n\r\n")
  return ['', ''] unless cut

  [raw.byteslice(0, cut), raw.byteslice(cut + 4, raw.bytesize - cut - 4)]
end

def ask(port, text)
  sock = TCPSocket.new('127.0.0.1', port)
  sock.write(text)
  reply = read_until_closed(sock, 5)
  sock.close
  reply.b
end

root = Dir.mktmpdir('kiln-static')
outside = Dir.mktmpdir('kiln-outside')
put(root, 'a.txt', "hello world\n")
put(root, 'index.html', '<h1>home</h1>')
put(root, 'data.bin', 'xyz')
put(root, '.env', 'SECRET=1')
Dir.mkdir(File.join(root, 'sub'))
put(root, 'sub/style.css', 'body{}')
Dir.mkdir(File.join(root, 'empty'))
put(outside, 'secret.txt', 'outside')
File.symlink(File.join(outside, 'secret.txt'), File.join(root, 'escape.txt'))
File.symlink(outside, File.join(root, 'escape-dir'))
File.symlink(File.join(root, 'a.txt'), File.join(root, 'alias.txt'))
File.symlink('.env', File.join(root, 'hidden-alias.txt'))
long_first = 'a' * 128
long_second = 'b' * 128
Dir.mkdir(File.join(root, long_first))
Dir.mkdir(File.join(root, long_first, long_second))
long_rel = "#{long_first}/#{long_second}/file.txt"
put(root, long_rel, 'deep')
BIG = big_bytes
big_path = put(root, 'big.bin', BIG)

files = Kiln::Static.new(root, max_age: 60)
app = Kiln::Router.new
app.get('/', files)
app.get('/files/*path', files)
app.seal!

puts '-- dates'
check 'IMF-fixdate', Kiln::HttpDate.parse('Sun, 06 Nov 1994 08:49:37 GMT') == 784_111_777
check 'RFC 850', Kiln::HttpDate.parse('Sunday, 06-Nov-94 08:49:37 GMT') == 784_111_777
check 'asctime', Kiln::HttpDate.parse('Sun Nov  6 08:49:37 1994') == 784_111_777
check 'invalid dates are nil',
      Kiln::HttpDate.parse('yesterday').nil? && Kiln::HttpDate.parse(nil).nil? &&
      Kiln::HttpDate.parse('Sun, 31 Feb 1994 08:49:37 GMT').nil?

puts '-- files'
plain = fetch(app, '/files/a.txt')
ETAG = plain.headers['ETag']
check 'file body', plain.status == 200 && plain.body == "hello world\n"
check 'content type by extension', plain.headers['Content-Type'] == 'text/plain; charset=utf-8'
check 'validators', plain.headers['ETag'] == ETAG && plain.headers['Last-Modified'] == STAMP_TEXT
check 'ranges advertised', plain.headers['Accept-Ranges'] == 'bytes'
check 'cache control', plain.headers['Cache-Control'] == 'public, max-age=60'
check 'unknown extension is octet-stream',
      fetch(app, '/files/data.bin').headers['Content-Type'] == 'application/octet-stream'
check 'nested file', fetch(app, '/files/sub/style.css').body == 'body{}'
check 'root serves the index', fetch(app, '/').body == '<h1>home</h1>'
check 'directory without index is 404', fetch(app, '/files/empty').status == 404
check 'missing file is 404', fetch(app, '/files/nope.txt').status == 404
check 'dotfile is 404', fetch(app, '/files/.env').status == 404
check 'symlink to a dotfile is 404', fetch(app, '/files/hidden-alias.txt').status == 404
check 'symlink out of the root is 404', fetch(app, '/files/escape.txt').status == 404
check 'a path longer than the stack buffer is served', fetch(app, "/files/#{long_rel}").body == 'deep'
root_real = File.realpath(root)
root_fd = Kiln::HttpNative.kiln_http_open_beneath(-1, root_real, root_real.bytesize)
final_fd = Kiln::HttpNative.kiln_http_open_beneath(root_fd, 'escape.txt', 10)
middle_fd = Kiln::HttpNative.kiln_http_open_beneath(root_fd, 'escape-dir/secret.txt', 21)
IO.for_fd(root_fd).close
check 'descriptor opener rejects final and intermediate symlinks', final_fd.negative? && middle_fd.negative?
check 'symlink inside the root is served', fetch(app, '/files/alias.txt').body == "hello world\n"
check 'dot-dot never reaches a file',
      fetch(app, '/files/../a.txt').status == 404 && fetch(app, '/files/%2E%2E/a.txt').status == 404
check 'encoded slash never reaches a file', fetch(app, '/files/sub%2Fstyle.css').status == 404
check 'encoded NUL is refused', fetch(app, '/files/a.txt%00').status == 400
dotted = Kiln::Router.new.get('/f/*path', Kiln::Static.new(root, dotfiles: true))
check 'dotfiles: true serves dotfiles', fetch(dotted, '/f/.env').body == 'SECRET=1'
raises('missing root', SystemCallError, '') { Kiln::Static.new(File.join(root, 'nope')) }
raises('root must be a directory', ArgumentError, 'not a directory') { Kiln::Static.new(File.join(root, 'a.txt')) }

puts '-- conditional requests'
fresh = fetch(app, '/files/a.txt', { 'If-None-Match' => ETAG })
check 'If-None-Match match is 304 without body or type',
      fresh.status == 304 && fresh.body.empty? && fresh.headers['ETag'] == ETAG && fresh.headers['Content-Type'].nil?
check 'weak If-None-Match matches', fetch(app, '/files/a.txt', { 'If-None-Match' => "W/#{ETAG}" }).status == 304
listed = fetch(app, '/files/a.txt', { 'If-None-Match' => "\"x\", #{ETAG}" }).status
check 'If-None-Match list and *', listed == 304 && fetch(app, '/files/a.txt', { 'If-None-Match' => '*' }).status == 304
check 'If-None-Match miss is 200', fetch(app, '/files/a.txt', { 'If-None-Match' => '"other"' }).status == 200
check 'If-Modified-Since equal is 304',
      fetch(app, '/files/a.txt', { 'If-Modified-Since' => STAMP_TEXT }).status == 304
check 'If-Modified-Since earlier is 200',
      fetch(app, '/files/a.txt', { 'If-Modified-Since' => 'Sat, 08 Sep 2001 00:00:00 GMT' }).status == 200
check 'invalid If-Modified-Since is ignored',
      fetch(app, '/files/a.txt', { 'If-Modified-Since' => 'soon' }).status == 200
check 'If-None-Match wins over If-Modified-Since',
      fetch(app, '/files/a.txt', { 'If-None-Match' => '"other"', 'If-Modified-Since' => STAMP_TEXT }).status == 200
check 'If-Match miss is 412', fetch(app, '/files/a.txt', { 'If-Match' => '"other"' }).status == 412
check 'If-Match is strong', fetch(app, '/files/a.txt', { 'If-Match' => "W/#{ETAG}" }).status == 412
check 'If-Match hit is 200', fetch(app, '/files/a.txt', { 'If-Match' => ETAG }).status == 200
check 'If-Unmodified-Since earlier is 412',
      fetch(app, '/files/a.txt', { 'If-Unmodified-Since' => 'Sat, 08 Sep 2001 00:00:00 GMT' }).status == 412
check 'a comma inside an entity tag is parsed as content',
      Kiln::Conditional.tag_listed?('"a,b"', '"a,b"', strong: true) &&
      Kiln::Conditional.tag_listed?('"other", W/"a,b"', '"a,b"', strong: false)
version_path = put(root, 'version.txt', 'one')
old_tag = fetch(app, '/files/version.txt').headers['ETag']
File.write(version_path, 'two')
File.utime(STAMP, STAMP, version_path)
versioned = fetch(app, '/files/version.txt', { 'If-None-Match' => old_tag })
check 'same-size replacement changes the ETag',
      versioned.status == 200 && versioned.body == 'two' && versioned.headers['ETag'] != old_tag

puts '-- ranges'
first = fetch(app, '/files/a.txt', { 'Range' => 'bytes=0-4' })
check 'first bytes', first.status == 206 && first.body == 'hello' && first.headers['Content-Range'] == 'bytes 0-4/12'
check 'open range', fetch(app, '/files/a.txt', { 'Range' => 'bytes=6-' }).body == "world\n"
check 'suffix range', fetch(app, '/files/a.txt', { 'Range' => 'bytes=-6' }).body == "world\n"
check 'range end past the file is clamped', fetch(app, '/files/a.txt', { 'Range' => 'bytes=6-999' }).body == "world\n"
check 'suffix longer than the file is the file', fetch(app, '/files/a.txt', { 'Range' => 'bytes=-99' }).status == 206
beyond = fetch(app, '/files/a.txt', { 'Range' => 'bytes=12-' })
check 'range past the end is 416', beyond.status == 416 && beyond.headers['Content-Range'] == 'bytes */12'
check 'zero suffix is 416', fetch(app, '/files/a.txt', { 'Range' => 'bytes=-0' }).status == 416
check 'reversed range is ignored', fetch(app, '/files/a.txt', { 'Range' => 'bytes=5-2' }).status == 200
check 'several ranges are ignored', fetch(app, '/files/a.txt', { 'Range' => 'bytes=0-1,3-4' }).status == 200
check 'other units are ignored', fetch(app, '/files/a.txt', { 'Range' => 'items=0-1' }).status == 200
check 'If-Range with the ETag keeps the range',
      fetch(app, '/files/a.txt', { 'Range' => 'bytes=0-4', 'If-Range' => ETAG }).status == 206
check 'If-Range with another ETag sends the file',
      fetch(app, '/files/a.txt', { 'Range' => 'bytes=0-4', 'If-Range' => '"old"' }).status == 200
check 'If-Range with the date keeps the range',
      fetch(app, '/files/a.txt', { 'Range' => 'bytes=0-4', 'If-Range' => STAMP_TEXT }).status == 206
head_req = Kiln::Request.new('HEAD', '/files/a.txt', { 'range' => 'bytes=0-1' }, nil)
head_res = Kiln::Response.new
app.call(Kiln::Context.new(head_req, head_res, nil, 'head', Kiln.now + 2))
check 'HEAD ignores Range', head_res.status == 200 && head_res.stream_length == 12 &&
                            head_res.headers['Content-Range'].nil?

puts '-- large files'
whole = fetch(app, '/files/big.bin')
check 'a large file is streamed with its length', whole.body == BIG && whole.status == 200
tail = fetch(app, '/files/big.bin', { 'Range' => 'bytes=1000-' })
check 'a large range', tail.status == 206 && tail.body == BIG.byteslice(1000, BIG_SIZE - 1000)
held_req = Kiln::Request.new('GET', '/files/big.bin', {}, nil)
held_res = Kiln::Response.new
app.call(Kiln::Context.new(held_req, held_res, nil, 'held', Kiln.now + 2))
File.rename(big_path, "#{big_path}.old")
File.symlink(File.join(outside, 'secret.txt'), big_path)
held_body = (+'').b
held_out = Kiln::Stream.new(->(_prefix, bytes) { held_body << bytes }, -> { false }, false, held_res.stream_length)
held_res.stream_body.call(held_out)
held_out.flush
check 'a large stream keeps its original file after a path swap', held_body == BIG
File.unlink(big_path)
File.rename("#{big_path}.old", big_path)
short = Kiln::Router.new.get('/s', ->(ctx) { ctx.res.stream(length: 5) { |out| out.write('abc') } })
raises('a stream shorter than its length', ArgumentError, 'wrote 3 of 5') { fetch(short, '/s') }
long = Kiln::Router.new.get('/l', ->(ctx) { ctx.res.stream(length: 2) { |out| out.write('abc') } })
raises('a stream longer than its length', ArgumentError, 'more than its 2') { fetch(long, '/l') }
raises('length is validated', ArgumentError, 'length') { Kiln::Response.new.stream(length: -1) { |_out| nil } }

log = Kiln::Log.new(StringIO.new)
network = Kiln::Router.new
network.get('/files/*path', files)
network.get('/short', ->(ctx) { ctx.res.stream(length: 10) { |out| out.write('abc') } })
network.get('/health', ->(ctx) { ctx.res.text('ok') })
network.seal!
[[:event, 0], [:event, 2], [:base, 0]].each do |backend, handlers|
  name = backend == :event ? "event/#{handlers}" : 'base'
  options = { log:, port: 0, host: '127.0.0.1', backend: }
  options[:handlers] = handlers if backend == :event
  server = Kiln::Server.new(network, nil, **options)
  server.start
  port = server.port

  head, body = split_reply(ask(port, "GET /files/big.bin HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n"))
  check "#{name}: large file has Content-Length, not chunked",
        head.include?("Content-Length: #{BIG_SIZE}") && !head.include?('chunked') && body == BIG
  heads = ask(port, "HEAD /files/big.bin HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n")
  check "#{name}: HEAD of a large file", heads.include?("Content-Length: #{BIG_SIZE}") && heads.end_with?("\r\n\r\n")
  piped = ask(port, "GET /files/big.bin HTTP/1.1\r\nHost: t\r\n\r\n" \
                    "GET /health HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n")
  check "#{name}: the connection stays open after a sized stream", piped.end_with?('ok') && piped.include?(BIG)
  ranged = ask(port, "GET /files/big.bin HTTP/1.1\r\nHost: t\r\nRange: bytes=-100\r\nConnection: close\r\n\r\n")
  check "#{name}: range over the wire",
        ranged.start_with?('HTTP/1.1 206') && ranged.end_with?(BIG.byteslice(BIG_SIZE - 100, 100))
  old = ask(port, "GET /files/big.bin HTTP/1.0\r\n\r\n")
  check "#{name}: HTTP/1.0 gets the length too", old.include?("Content-Length: #{BIG_SIZE}") && old.end_with?(BIG)
  cut = ask(port, "GET /short HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n")
  check "#{name}: a stream that falls short is cut off",
        cut.include?('Content-Length: 10') && split_reply(cut)[1] == 'abc'
  health = ask(port, "GET /health HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n")
  check "#{name}: server still answers", health.end_with?('ok')
  server.shutdown(grace: 1.0)
end
log.close
puts 'done'
