require 'kiln'
require 'stringio'
require 'test/support'

def check(label, passed)
  raise "FAIL #{label}" unless passed

  puts "ok   #{label}"
end

def raises(label, klass, fragment)
  yield
  raise "FAIL #{label}: nothing raised"
rescue klass => caught
  check(label, caught.message.include?(fragment))
end

def request(verb, path, headers, body)
  Kiln::Request.new(verb, path, headers, body)
end

def run_app(app, req)
  res = Kiln::Response.new
  app.call(Kiln::Context.new(req, res, nil, 'json', Kiln.now + 5.0))
  res
end

puts '-- parse'
doc = Kiln::Json.parse('{"s":"x\u00e9\n","i":-3,"f":2.5,"t":true,"n":null,"a":[1,[2,{}]],"o":{"k":"v"}}')
check 'object with every value type', doc['s'] == "x\u00e9\n" && doc['i'] == -3 && doc['f'] == 2.5 &&
                                      doc['t'] == true && doc['n'].nil? && doc['a'] == [1, [2, {}]] &&
                                      doc['o'] == { 'k' => 'v' }
check 'keys are strings', doc.keys.first == 's'
check 'top-level scalar', Kiln::Json.parse('42') == 42 && Kiln::Json.parse('"x"') == 'x'
check 'integer past int64 is a Bignum', Kiln::Json.parse('123456789012345678901234') == 123_456_789_012_345_678_901_234
check 'uint64 past int64 is a Bignum', Kiln::Json.parse('18446744073709551615') == 18_446_744_073_709_551_615
check 'int64 bounds stay exact', Kiln::Json.parse('[-9223372036854775808,9223372036854775807]') ==
                                 [-9_223_372_036_854_775_808, 9_223_372_036_854_775_807]
check 'float overflow is Infinity', Kiln::Json.parse('1e400') == Float::INFINITY
check 'escaped NUL survives', Kiln::Json.parse('"a\u0000b"').bytesize == 3
check 'surrogate pair decodes', Kiln::Json.parse('"\ud83d\ude00"') == "\u{1F600}"
check 'duplicate key: last wins', Kiln::Json.parse('{"a":1,"a":2}') == { 'a' => 2 }
shared = Kiln::Json.parse('[{"name":1},{"name":2}]')
check 'repeated keys parse independently', shared[0]['name'] == 1 && shared[1]['name'] == 2
check 'parsed key is frozen', shared[1].keys[0].frozen?
deep_ok = Kiln::Json.parse(('[' * 100) + (']' * 100))
check 'nesting at the limit parses', deep_ok.size == 1
check 'max_nesting is configurable', Kiln::Json.parse('[[1]]', max_nesting: 2) == [[1]]
raises('nesting past the limit', Kiln::JsonError, 'nesting too deep') { Kiln::Json.parse(('[' * 101) + (']' * 101)) }
raises('max_nesting lowers the limit', Kiln::JsonError, 'nesting') { Kiln::Json.parse('[[1]]', max_nesting: 1) }
raises('trailing comma', Kiln::JsonError, 'at byte 6') { Kiln::Json.parse('{"a":1,}') }
raises('trailing garbage', Kiln::JsonError, 'byte') { Kiln::Json.parse('{} x') }
raises('empty input', Kiln::JsonError, 'empty') { Kiln::Json.parse('') }
raises('invalid UTF-8', Kiln::JsonError, 'UTF-8') { Kiln::Json.parse("\"\xff\"") }
raises('lone surrogate', Kiln::JsonError, 'surrogate') { Kiln::Json.parse('"\ud800"') }
raises('unescaped control', Kiln::JsonError, 'byte') { Kiln::Json.parse("\"a\tb\"") }
raises('NaN literal', Kiln::JsonError, 'byte') { Kiln::Json.parse('NaN') }
raises('comment', Kiln::JsonError, 'byte') { Kiln::Json.parse('[1/*x*/]') }

puts '-- generate'
check 'scalars', Kiln::Json.generate(nil) == 'null' && Kiln::Json.generate(true) == 'true' &&
                 Kiln::Json.generate(-7) == '-7' && Kiln::Json.generate('x') == '"x"'
check 'float formatting', Kiln::Json.generate([0.1, 2.5, 1.0, -0.0, 1e20, 1.5e-7, 1e22]) ==
                          '[0.1,2.5,1.0,-0.0,100000000000000000000.0,1.5e-7,1e22]'
floats = [0.1, 1.0 / 3, 123_456.789, 2.2250738585072014e-308, 1.7976931348623157e308]
check 'floats parse back exactly', Kiln::Json.parse(Kiln::Json.generate(floats)) == floats
check 'Bignum', Kiln::Json.generate(2**70) == '1180591620717411303424'
check 'escapes', Kiln::Json.generate("q\"b\\n\n\r\t\b\f\u0001/") == '"q\\"b\\\\n\\n\\r\\t\\b\\f\\u0001/"'
ascii_bytes = (0..127).map { |byte| byte.chr }.join * 2
check 'SWAR safe ASCII runs round trip', Kiln::Json.parse(Kiln::Json.generate(ascii_bytes)) == ascii_bytes
check 'NUL is escaped, not truncated', Kiln::Json.generate("a\u0000b") == '"a\\u0000b"'
check 'UTF-8 is written as-is', Kiln::Json.generate("д\u{1F600}") == "\"д\u{1F600}\""
check 'symbol keys and values', Kiln::Json.generate({ id: 1, kind: :user }) == '{"id":1,"kind":"user"}'
check 'integer keys become strings', Kiln::Json.generate({ 1 => 'a' }) == '{"1":"a"}'
check 'bignum keys become strings', Kiln::Json.generate({ (1 << 80) => 1 }) ==
                                    '{"1208925819614629174706176":1}'
check 'typed hash', Kiln::Json.generate({ 'a' => 1, 'b' => 2 }) == '{"a":1,"b":2}'
check 'typed arrays', Kiln::Json.generate([[1, 2], %w[x y], [1.5]]) == '[[1,2],["x","y"],[1.5]]'
grown = +'ab'
grown << "c\u0000d"
check 'mutable String values and keys', Kiln::Json.generate({ 'k' => grown, grown => [grown] }) ==
                                        '{"k":"abc\\u0000d","abc\\u0000d":["abc\\u0000d"]}'
headers_box = Kiln::Headers.new
headers_box['Allow'] = 'GET'
check 'header value in a Hash literal', Kiln::Json.generate({ 'allow' => headers_box['Allow'] }) == '{"allow":"GET"}'
check 'empty containers', Kiln::Json.generate({ 'a' => [], 'b' => {} }) == '{"a":[],"b":{}}'
sample = { 'users' => [{ 'id' => 1, 'name' => 'Ann "A"', 'tags' => %w[a б], 'score' => 9.75, 'admin' => false,
                         'boss' => nil }], 'total' => 1 }
check 'round trip', Kiln::Json.parse(Kiln::Json.generate(sample)) == sample
raises('NaN', Kiln::JsonGenerateError, 'NaN') { Kiln::Json.generate([Float::NAN]) }
raises('Infinity', Kiln::JsonGenerateError, 'Infinity') { Kiln::Json.generate({ 'x' => Float::INFINITY }) }
raises('invalid UTF-8', Kiln::JsonGenerateError, 'UTF-8') { Kiln::Json.generate(["\xff".b]) }
raises('arbitrary object', Kiln::JsonGenerateError, 'unsupported object') { Kiln::Json.generate([Object.new]) }
raises('UTF-16 surrogate encoded as UTF-8', Kiln::JsonGenerateError, 'UTF-8') { Kiln::Json.generate(["\xED\xA0\x80".b]) }
check 'control characters use upper-case hex', Kiln::Json.generate("\u001f\u000b") == '"\\u001F\\u000B"'
mixed = "Заказ №7 — «доставлен» \u{1F680} \"ok\"\n\t東京"
check 'Cyrillic, CJK, emoji and escapes in one string', Kiln::Json.parse(Kiln::Json.generate([mixed]))[0] == mixed
many = Array.new(60_000) { |index| { 'id' => index, 'name' => "товар-#{index}" } }
big = Kiln::Json.generate(many)
check 'a document past the scratch pool is written whole', big.bytesize > 1_048_576 &&
                                                         Kiln::Json.parse(big).size == 60_000
check 'the scratch pool is reused after a large document', Kiln::Json.generate({ 'a' => 'б' }) == '{"a":"б"}'
loop_list = []
loop_list << loop_list
raises('circular structure', Kiln::JsonGenerateError, 'nesting') { Kiln::Json.generate(loop_list) }

puts '-- media types'
check 'application/json', Kiln::Media.json?('application/json')
check 'charset utf-8 and case', Kiln::Media.json?('Application/JSON; Charset="UTF-8"')
check 'structured +json suffix', Kiln::Media.json?('application/problem+json')
check 'other charset refused', !Kiln::Media.json?('application/json; charset=latin1')
check 'text/plain refused', !Kiln::Media.json?('text/plain') && !Kiln::Media.json?(nil)
check 'form type', Kiln::Media.form?('application/x-www-form-urlencoded; charset=utf-8')

puts '-- request bodies'
json_req = request('POST', '/u', { 'content-type' => 'application/json' }, '{"name":"Ann","age":30}')
first_json = json_req.json
check 'Request#json', first_json['name'] == 'Ann' && first_json['age'] == 30
check 'Request#json is memoized', json_req.json.equal?(first_json)
limited_req = request('POST', '/u', { 'content-type' => 'application/json' }, '[[1]]')
limited_req.json(max_nesting: 3)
raises('Request#json reapplies a stricter nesting limit', Kiln::BadRequest, 'nesting') do
  limited_req.json(max_nesting: 1)
end
raises('missing content type -> UnsupportedMediaType', Kiln::UnsupportedMediaType, 'application/json') do
  request('POST', '/u', {}, '{}').json
end
raises('bad body -> BadRequest', Kiln::BadRequest, 'invalid JSON: trailing comma') do
  request('POST', '/u', { 'content-type' => 'application/json' }, '[1,]').json
end
raises('nil body -> BadRequest', Kiln::BadRequest, 'invalid JSON') do
  request('POST', '/u', { 'content-type' => 'application/json' }, nil).json
end
query_req = request('GET', '/s?a=1&b=x+y&c=%D0%B4&d&e=&a=2&bad=%zz&&p=100%25', {}, nil)
check 'query_params decodes, last value wins', query_req.query_params ==
                                               { 'a' => '2', 'b' => 'x y', 'c' => 'д', 'd' => '', 'e' => '',
                                                 'bad' => '%zz', 'p' => '100%' }
check 'empty query', request('GET', '/s', {}, nil).query_params.empty?
raises('query with invalid UTF-8', Kiln::BadRequest, 'UTF-8') { request('GET', '/s?x=%ff', {}, nil).query_params }
form_req = request('POST', '/f', { 'content-type' => 'application/x-www-form-urlencoded' }, 'name=A+B&n=%2B1')
check 'form', form_req.form == { 'name' => 'A B', 'n' => '+1' }
raises('form needs its content type', Kiln::UnsupportedMediaType, 'urlencoded') do
  request('POST', '/f', { 'content-type' => 'application/json' }, 'a=1').form
end

puts '-- cookies'
cookie_req = request('GET', '/', { 'cookie' => 'a=1; b="two" ;a=3; =x; c; d=' }, nil)
check 'cookie parsing, first value wins', cookie_req.cookies == { 'a' => '1', 'b' => 'two', 'd' => '' }
check 'cookie lookup', cookie_req.cookie('b') == 'two' && cookie_req.cookie('zz').nil?
check 'no cookie header', request('GET', '/', {}, nil).cookies.empty?
cookie_res = Kiln::Response.new
cookie_res.set_cookie('sid', 'abc123', max_age: 3600, secure: true)
cookie_res.set_cookie('theme', 'dark', http_only: false, same_site: nil)
cookie_res.delete_cookie('old')
set_values = []
cookie_res.headers.each { |name, value| set_values << value if name == 'Set-Cookie' }
check 'Set-Cookie headers', set_values == ['sid=abc123; Path=/; Max-Age=3600; Secure; HttpOnly; SameSite=Lax',
                                           'theme=dark; Path=/', 'old=; Path=/; Max-Age=0']
raises('cookie value with ;', ArgumentError, 'value') { Kiln::Response.new.set_cookie('a', 'x;y') }
raises('cookie value with CRLF', ArgumentError, 'value') { Kiln::Response.new.set_cookie('a', "x\r\nSet-Cookie: b") }
raises('cookie name', ArgumentError, 'name') { Kiln::Response.new.set_cookie('a b', 'x') }
raises('SameSite=None needs Secure', ArgumentError, 'secure') do
  Kiln::Response.new.set_cookie('a', 'x', same_site: 'None')
end

puts '-- dispatch'
log_io = StringIO.new
log = Kiln::Log.new(log_io)
router = Kiln::Router.new
                     .post('/echo', lambda { |ctx|
                       ctx.res.json_value({ 'got' => ctx.req.json, 'q' => ctx.req.query_params })
                     })
                     .get('/upstream', ->(ctx) { ctx.res.json_value(Kiln::Json.parse('{oops')) })
                     .get('/bad', ->(ctx) { ctx.res.json_value({ 'x' => Float::NAN }) })
                     .seal!
app = Kiln::Rescue.new(router, log)
ok_res = run_app(app, request('POST', '/echo?v=1', { 'content-type' => 'application/json' }, '{"a":[1,2]}'))
check 'echo: 200 with JSON body', ok_res.status == 200 && ok_res.body == '{"got":{"a":[1,2]},"q":{"v":"1"}}' &&
                                  ok_res.headers['content-type'] == 'application/json'
bad_res = run_app(app, request('POST', '/echo', { 'content-type' => 'application/json' }, '{"a":'))
check 'invalid body: 400 with reason', bad_res.status == 400 && bad_res.body.start_with?('invalid JSON: ')
type_res = run_app(app, request('POST', '/echo', { 'content-type' => 'text/plain' }, '{}'))
check 'wrong content type: 415', type_res.status == 415
up_res = run_app(app, request('GET', '/upstream', {}, nil))
check 'JsonError outside Request#json is a 500', up_res.status == 500
gen_res = run_app(app, request('GET', '/bad', {}, nil))
check 'generate error is a 500', gen_res.status == 500

puts '-- server'
%i[event base].each do |backend|
  server = Kiln::Server.new(app, nil, log: log, port: 0, host: '127.0.0.1', backend: backend)
  server.start
  body = '{"name":"Ann"}'
  sock = TCPSocket.new('127.0.0.1', server.port)
  sock.write("POST /echo?x=%D0%B4 HTTP/1.1\r\nHost: t\r\nContent-Type: application/json\r\n" \
             "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
  reply = read_until_closed(sock, 3).force_encoding(Encoding::UTF_8)
  sock.close
  check "#{backend}: JSON round trip over HTTP",
        reply.start_with?('HTTP/1.1 200') && reply.end_with?('{"got":{"name":"Ann"},"q":{"x":"д"}}')
  sock = TCPSocket.new('127.0.0.1', server.port)
  sock.write("POST /echo HTTP/1.1\r\nHost: t\r\nContent-Type: application/json\r\nContent-Length: 2\r\n" \
             "Connection: close\r\n\r\n[,")
  reply = read_until_closed(sock, 3)
  sock.close
  check "#{backend}: invalid JSON over HTTP is 400", reply.start_with?('HTTP/1.1 400')
  server.shutdown(grace: 1.0)
end
log.close
puts 'done'
