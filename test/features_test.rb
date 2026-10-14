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
rescue klass => e
  check(label, e.message.include?(fragment))
end

def hit(app, verb, target)
  Kiln::Testing.call(app, verb, target)
end

def body_of(app, verb, target) = hit(app, verb, target).body

def say(text) = ->(ctx) { ctx.res.text(text) }

def show_params = ->(ctx) { ctx.res.text(ctx.req.params.map { |key, value| "#{key}=#{value}" }.join(',')) }

log_io = StringIO.new
log = Kiln::Log.new(log_io)

puts '-- router: wildcard and order'
files = Kiln::Router.new
files.get('/files/readme', say('readme'))
files.get('/files/*path', show_params)
files.get('/u/:id/files/*rest', show_params)
check 'static route before glob wins', body_of(files, 'GET', '/files/readme') == 'readme'
check 'glob takes the rest of the path', body_of(files, 'GET', '/files/a/b%20c/d.txt') == 'path=a/b c/d.txt'
check 'glob takes one segment', body_of(files, 'GET', '/files/x') == 'path=x'
check 'glob needs at least one segment', hit(files, 'GET', '/files').status == 404
check 'glob after a parameter', body_of(files, 'GET', '/u/7/files/q/r') == 'id=7,rest=q/r'
check 'glob refuses ..', hit(files, 'GET', '/files/a/../etc').status == 404
check 'glob refuses encoded ..', hit(files, 'GET', '/files/%2E%2E/etc').status == 404
check 'glob refuses encoded slash', hit(files, 'GET', '/files/a%2Fb').status == 404
check 'glob refuses .', hit(files, 'GET', '/files/./x').status == 404
check 'HEAD falls back to GET on a glob', hit(files, 'HEAD', '/files/x').status == 200
check 'glob 405 lists its methods', hit(files, 'POST', '/files/x').headers['Allow'] == 'GET, HEAD'

ordered = Kiln::Router.new
ordered.get('/users/new', say('new'))
ordered.post('/users/:id', show_params)
ordered.get('/users/:id', show_params)
check 'static GET wins for GET', body_of(ordered, 'GET', '/users/new') == 'new'
check 'a parameter route serves a verb the static route lacks', body_of(ordered, 'POST', '/users/new') == 'id=new'
early = Kiln::Router.new
early.get('/*all', say('glob'))
early.get('/a/b', say('static'))
check 'an earlier glob keeps priority (registration order)', body_of(early, 'GET', '/a/b') == 'glob'

puts '-- router: sealed fast path'
fast = Kiln::Router.new
fast.get('/', say('root'))
fast.get('/a', say('a'))
fast.get('/:x', show_params)
fast.post('/a', say('post a'))
fast.get('/b', say('b'))
probes = [%w[GET /], %w[GET /a], %w[POST /a], %w[HEAD /a], %w[GET /b], %w[DELETE /a], %w[GET /zz]]
before = probes.map { |verb, path| [hit(fast, verb, path).status, body_of(fast, verb, path)] }
fast.seal!
after = probes.map { |verb, path| [hit(fast, verb, path).status, body_of(fast, verb, path)] }
check 'sealing does not change any answer', before == after
check 'sealed router keeps registration order', after[1] == [200, 'a'] && after[4] == [200, 'x=b']
shadow = Kiln::Router.new
shadow.get('/:x', show_params)
shadow.get('/b', say('b'))
shadow.seal!
check 'sealed fast path respects an earlier parameter route', body_of(shadow, 'GET', '/b') == 'x=b'

puts '-- router: trailing slash'
strict = Kiln::Router.new
strict.get('/docs', say('docs'))
check 'strict: trailing slash is 404', hit(strict, 'GET', '/docs/').status == 404
lenient = Kiln::Router.new(trailing_slash: :redirect)
lenient.get('/docs', say('docs'))
lenient.post('/docs', say('posted'))
moved = hit(lenient, 'GET', '/docs/?page=2')
check 'redirect: GET gets 301 keeping the query', moved.status == 301 && moved.headers['Location'] == '/docs?page=2'
check 'redirect: POST gets 308', hit(lenient, 'POST', '/docs/').status == 308
check 'redirect: unknown path stays 404', hit(lenient, 'GET', '/nope/').status == 404
check 'redirect: no redirect for a backslash path', hit(lenient, 'GET', '/\\docs/').status != 301
raises('trailing_slash is validated', ArgumentError, 'trailing_slash') { Kiln::Router.new(trailing_slash: :ignore) }

puts '-- router: custom fallbacks, wraps, errors'
custom = Kiln::Router.new
custom.get('/x', say('x'))
custom.not_found(->(ctx) { ctx.res.json_value({ 'error' => 'not found' }, status: 404) })
custom.method_not_allowed(->(ctx) { ctx.res.json_value({ 'allow' => ctx.res.headers['Allow'] }, status: 405) })
miss = hit(custom, 'GET', '/y')
check 'custom 404', miss.status == 404 && miss.body == '{"error":"not found"}'
wrong = hit(custom, 'DELETE', '/x')
check 'custom 405 sees Allow', wrong.status == 405 && wrong.body == '{"allow":"GET, HEAD"}'
trail = []
tag = lambda do |name|
  lambda do |nxt|
    lambda do |ctx|
      trail << name
      nxt.call(ctx)
    end
  end
end
wrapped = Kiln::Router.new
wrapped.scope('/api', wrap: tag.call('outer')) do |api|
  api.scope('/v1', wrap: tag.call('inner')) { |v1| v1.get('/ping', say('pong')) }
  api.get('/plain', say('plain'))
end
wrapped.get('/free', say('free'))
body_of(wrapped, 'GET', '/api/v1/ping')
check 'scope wraps run outer to inner', trail == %w[outer inner]
trail.clear
body_of(wrapped, 'GET', '/api/plain')
body_of(wrapped, 'GET', '/free')
check 'a wrap covers only its scope', trail == %w[outer]
raises('duplicate route', ArgumentError, 'duplicate route') { Kiln::Router.new.get('/a', say('1')).get('/a', say('2')) }
raises('glob must be last', ArgumentError, 'last segment') { Kiln::Router.new.get('/*a/b', say('x')) }
raises('empty parameter name', ArgumentError, 'empty parameter') { Kiln::Router.new.get('/:/b', say('x')) }
encoded = Kiln::Router.new.get('/caf%C3%A9', say('cafe'))
check 'percent-encoded static pattern matches', body_of(encoded, 'GET', '/caf%C3%A9') == 'cafe'

puts '-- testing helper'
api = Kiln::Router.new
api.post('/echo', ->(ctx) { ctx.res.json_value({ 'got' => ctx.req.json }) })
api.get('/left', ->(ctx) { ctx.res.text(Kiln.remaining.positive? ? 'deadline set' : 'none') })
api.get('/wait', ->(ctx) { ctx.res.text(Kiln.pop(Queue.new).to_s) })
api.get('/boom', ->(_ctx) { raise ArgumentError, 'boom' })
echoed = Kiln::Testing.json(api, 'POST', '/echo', { 'a' => [1, 2] })
check 'Testing.json', echoed.status == 200 && echoed.body == '{"got":{"a":[1,2]}}'
check 'Testing.call installs the deadline', body_of(api, 'GET', '/left') == 'deadline set'
bad = Kiln::Testing.call(api, 'POST', '/echo', headers: { 'Content-Type' => 'application/json' }, body: '[1,')
check 'Testing.call maps BadRequest to 400', bad.status == 400
check 'Kiln.pop honours the deadline (504)', Kiln::Testing.call(api, 'GET', '/wait', timeout: 0.05).status == 504
raises('unmapped errors reach the test', ArgumentError, 'boom') { hit(api, 'GET', '/boom') }
check 'Kiln.pop without a deadline', Kiln.pop(Queue.new.tap { |queue| queue << 5 }) == 5

puts '-- middleware'
plain = ->(ctx) { ctx.res.text('ok') }
framed = lambda do |ctx|
  ctx.res.headers['X-Frame-Options'] = 'SAMEORIGIN'
  ctx.res.text('ok')
end
defaults = { 'X-Frame-Options' => 'DENY', 'X-Content-Type-Options' => 'nosniff' }
headed = hit(Kiln::DefaultHeaders.new(plain, defaults), 'GET', '/')
check 'DefaultHeaders adds missing headers', headed.headers['X-Frame-Options'] == 'DENY' &&
                                             headed.headers['X-Content-Type-Options'] == 'nosniff'
kept = hit(Kiln::DefaultHeaders.new(framed, defaults), 'GET', '/')
check 'DefaultHeaders keeps what the handler set', kept.headers['X-Frame-Options'] == 'SAMEORIGIN'
cors = Kiln::Cors.new(plain, origins: ['https://app.example'], headers: %w[Content-Type X-Token],
                             expose: ['X-Request-Id'], credentials: true, max_age: 300)
pre = Kiln::Testing.call(cors, 'OPTIONS', '/x',
                         headers: { 'Origin' => 'https://app.example', 'Access-Control-Request-Method' => 'PUT',
                                    'Access-Control-Request-Headers' => 'content-type, x-token' })
check 'preflight allowed', pre.status == 204 && pre.headers['Access-Control-Allow-Origin'] == 'https://app.example' &&
                           pre.headers['Access-Control-Allow-Methods'].include?('PUT') &&
                           pre.headers['Access-Control-Allow-Credentials'] == 'true' &&
                           pre.headers['Access-Control-Max-Age'] == '300' && pre.body == ''
denied = Kiln::Testing.call(cors, 'OPTIONS', '/x',
                            headers: { 'Origin' => 'https://evil.example', 'Access-Control-Request-Method' => 'PUT' })
check 'preflight from another origin gets no grant', denied.status == 204 &&
                                                     denied.headers['Access-Control-Allow-Origin'].nil?
odd = Kiln::Testing.call(cors, 'OPTIONS', '/x',
                         headers: { 'Origin' => 'https://app.example', 'Access-Control-Request-Method' => 'PUT',
                                    'Access-Control-Request-Headers' => 'x-other' })
check 'preflight with an unlisted header gets no grant', odd.headers['Access-Control-Allow-Origin'].nil?
real = Kiln::Testing.call(cors, 'GET', '/x', headers: { 'Origin' => 'https://APP.example' })
check 'actual request is stamped', real.body == 'ok' &&
                                   real.headers['Access-Control-Allow-Origin'] == 'https://APP.example' &&
                                   real.headers['Access-Control-Expose-Headers'] == 'X-Request-Id' &&
                                   real.headers['Vary'] == 'Origin'
check 'no Origin, no CORS headers', hit(cors, 'GET', '/x').headers['Access-Control-Allow-Origin'].nil?
open_cors = Kiln::Cors.new(plain, origins: ['*'])
star = Kiln::Testing.call(open_cors, 'GET', '/x', headers: { 'Origin' => 'https://any.example' })
check 'origins "*" answers *', star.headers['Access-Control-Allow-Origin'] == '*'
put_only = Kiln::Cors.new(plain, origins: ['https://app.example'], methods: ['PUT'])
put_preflight = Kiln::Testing.call(put_only, 'OPTIONS', '/x',
                                   headers: { 'Origin' => 'https://app.example',
                                              'Access-Control-Request-Method' => 'PUT' })
get_preflight = Kiln::Testing.call(put_only, 'OPTIONS', '/x',
                                   headers: { 'Origin' => 'https://app.example',
                                              'Access-Control-Request-Method' => 'GET' })
get_actual = Kiln::Testing.call(put_only, 'GET', '/x', headers: { 'Origin' => 'https://app.example' })
check 'CORS allows only configured preflight methods', put_preflight.headers['Access-Control-Allow-Methods'] == 'PUT' &&
                                                       get_preflight.headers['Access-Control-Allow-Origin'].nil?
check 'CORS does not stamp an unlisted actual method', get_actual.headers['Access-Control-Allow-Origin'].nil?
raises('"*" with credentials', ArgumentError, 'credentials') do
  Kiln::Cors.new(plain, origins: ['*'], credentials: true)
end

puts '-- tasks'
token = Kiln::Token.new
check 'token wait times out', token.wait(0.02) == false
Thread.new do
  Kernel.sleep 0.02
  token.cancel
end
check 'token wait wakes on cancel', token.wait(2.0) == true && token.cancelled?
tasks = Kiln::Tasks.new(log)
ticks = Queue.new
seen = Queue.new
tasks.every('ticker', 0.02) { |_t| ticks << 1 }
tasks.every('flaky', 0.02) { |_t| raise 'flaky tick' }
tasks.spawn('waiter') { |task_token| seen << (task_token.wait(10.0) ? :cancelled : :timeout) }
wait_for { ticks.size >= 3 }
check 'every ticks repeatedly', ticks.size >= 3
check 'tasks are alive', tasks.size == 3
check 'shutdown cancels cooperative tasks', tasks.shutdown(grace: 2.0).zero? && seen.pop == :cancelled
check 'no task is left', tasks.size.zero?
raises('spawn after shutdown', ArgumentError, 'shut down') { tasks.spawn('late') { nil } }
stuck = Kiln::Tasks.new(log)
stuck.spawn('ignores token') { Kernel.sleep 30 }
check 'a stuck task is killed after grace', stuck.shutdown(grace: 0.05) == 1 && stuck.size.zero?
finished = Kiln::Tasks.new(log)
finished.spawn('once') { nil }
wait_for { finished.size.zero? }
check 'a finished task is forgotten', finished.size.zero?

puts '-- run with signals'
server = Kiln::Server.new(say('up'), nil, log:, port: 0, host: '127.0.0.1')
run_tasks = Kiln::Tasks.new(log)
run_tasks.every('noop', 0.05) { |_t| nil }
reply = Queue.new
Thread.new do
  port = 0
  wait_for do
    port = begin
      server.port
    rescue StandardError
      0
    end
    port.to_i.positive?
  end
  sock = TCPSocket.new('127.0.0.1', port)
  sock.write("GET / HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n")
  reply << read_until_closed(sock, 3)
  sock.close
  Process.kill('TERM', Process.pid)
end
left = server.run(grace: 2.0, tasks: run_tasks)
check 'run served while waiting', reply.pop.end_with?('up')
check 'SIGTERM ends run with nothing in flight', left.zero?
check 'run stops tasks', run_tasks.size.zero?
refused = begin
  TCPSocket.new('127.0.0.1', server.port).close
  false
rescue SystemCallError
  true
end
check 'listener is closed after run', refused

held = Kiln::Server.new(say('hold'), nil, log:, port: 0, host: '127.0.0.1')
held.start
trap_reader, trap_writer = IO.pipe
Signal.trap('USR1') { trap_writer.write_nonblock('1', exception: false) }
failed = Kiln::Server.new(say('no'), nil, log:, port: 0, host: '127.0.0.1')
failed_run = begin
  failed.run(grace: 0.5, signals: ['USR1'])
  false
rescue IOError
  true
end
check 'run raises when the event server is already up', failed_run
Process.kill('USR1', Process.pid)
restored = nil
begin
  wait_for { restored = trap_reader.read_nonblock(1, exception: false); restored == '1' }
rescue IOError
  nil
end
check 'a failed run restores the previous trap', restored == '1'
Signal.trap('USR1', 'DEFAULT')
trap_reader.close
trap_writer.close
held.shutdown(grace: 0.5)

again_reader, again_writer = IO.pipe
Signal.trap('USR2') { again_writer.write_nonblock('1', exception: false) }
again = Kiln::Server.new(say('up'), nil, log:, port: 0, host: '127.0.0.1')
Thread.new do
  port = 0
  wait_for do
    port = begin
      again.port
    rescue StandardError
      0
    end
    port.to_i.positive?
  end
  Process.kill('USR2', Process.pid)
end
again.run(grace: 1.0, signals: ['USR2'])
Process.kill('USR2', Process.pid)
again_hit = nil
begin
  wait_for { again_hit = again_reader.read_nonblock(1, exception: false); again_hit == '1' }
rescue IOError
  nil
end
check 'run restores the previous trap', again_hit == '1'
Signal.trap('USR2', 'DEFAULT')
again_reader.close
again_writer.close

log.close
logged = log_io.string
check 'task errors are logged', logged.include?('task flaky: RuntimeError: flaky tick')
check 'run logs the signal', logged.include?('SIGTERM received')
puts 'done'
