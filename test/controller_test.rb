require 'kiln'
require 'stringio'
require 'test/support'

def check(label, passed)
  raise "FAIL #{label}" unless passed

  puts "ok   #{label}"
end

def refuses(label, fragment)
  yield
  raise "FAIL #{label}: nothing raised"
rescue ArgumentError => e
  check(label, e.message.include?(fragment))
end

def hit(app, verb, target) = Kiln::Testing.call(app, verb, target)

class ControllerUsers < Kiln::Controller
  def index = res.text('users')
  def show = res.text("user #{params['id']}")
  def create = res.text('created', status: 201)
  def update = res.text("updated #{params['id']}")
  def destroy = res.text("destroyed #{params['id']}")
  def search = res.text("search #{req.query_params['q']}")
  def ban = res.text("banned #{who}")
  def export = res.text('export')
  def avatar = res.text("avatar #{who}")

  def visits
    @visits = (@visits || 0) + 1
    res.text("visits #{@visits}")
  end

  private

  def who = "##{params['id']}"
end

class ControllerBooks < Kiln::Controller
  def index = res.text('books')
  def show = res.text("book #{params['id']}")
  def search = res.text('book search')
end

class ControllerSlow < Kiln::Controller
  def show
    @mine = params['id']
    Kernel.sleep 0.05
    res.text("slow #{@mine}")
  end
end

USER_HANDLERS = {
  index: ->(ctx) { ControllerUsers.new(ctx).index },
  show: ->(ctx) { ControllerUsers.new(ctx).show },
  create: ->(ctx) { ControllerUsers.new(ctx).create },
  update: ->(ctx) { ControllerUsers.new(ctx).update },
  destroy: ->(ctx) { ControllerUsers.new(ctx).destroy }
}.freeze
BOOK_HANDLERS = {
  index: ->(ctx) { ControllerBooks.new(ctx).index },
  show: ->(ctx) { ControllerBooks.new(ctx).show }
}.freeze
SLOW_HANDLERS = { show: ->(ctx) { ControllerSlow.new(ctx).show } }.freeze

module ControllerRoutes
  class << self
    def configure(router)
      users(router)
      books(router)
    end

    private

    def users(router)
      router.get('/users/search', ->(ctx) { ControllerUsers.new(ctx).search })
      router.get('/users/export', ->(ctx) { ControllerUsers.new(ctx).export })
      router.post('/users/:id/ban', ->(ctx) { ControllerUsers.new(ctx).ban })
      router.get('/users/:id/avatar', ->(ctx) { ControllerUsers.new(ctx).avatar })
      router.get('/users/:id/visits', ->(ctx) { ControllerUsers.new(ctx).visits })
      router.resources('/users', USER_HANDLERS)
    end

    def books(router)
      router.get('/books/search', ->(ctx) { ControllerBooks.new(ctx).search })
      router.resources('/books', BOOK_HANDLERS)
    end
  end
end

class ControllerGuard
  def initialize(nxt) = @next = nxt

  def call(ctx)
    ctx.res.headers['X-Guard'] = 'on'
    @next.call(ctx)
  end
end

puts '-- controller resources'
router = Kiln::Router.new.configure(ControllerRoutes).seal!

check 'router module configures resources', hit(router, 'GET', '/users').body == 'users'
check 'index', hit(router, 'GET', '/users').body == 'users'
check 'show reads params through the controller', hit(router, 'GET', '/users/7').body == 'user 7'
created = hit(router, 'POST', '/users')
check 'create sets its status', created.status == 201 && created.body == 'created'
check 'update via PUT', hit(router, 'PUT', '/users/7').body == 'updated 7'
check 'update via PATCH', hit(router, 'PATCH', '/users/7').body == 'updated 7'
check 'destroy', hit(router, 'DELETE', '/users/7').body == 'destroyed 7'
check 'HEAD falls back to show', hit(router, 'HEAD', '/users/7').status == 200

puts '-- custom routes in the router module'
check 'static custom route wins over resource show',
      hit(router, 'GET', '/users/search?q=ann').body == 'search ann'
check 'custom route dispatches to controller action', hit(router, 'GET', '/users/export').body == 'export'
check 'member path gets :id and private helpers', hit(router, 'POST', '/users/7/ban').body == 'banned #7'
check 'member path dispatches to controller action', hit(router, 'GET', '/users/7/avatar').body == 'avatar #7'
check 'show still answers other ids', hit(router, 'GET', '/users/searching').body == 'user searching'
wrong = hit(router, 'GET', '/users/7/ban')
check 'member route keeps its method (405 with Allow)', wrong.status == 405 && wrong.headers['Allow'] == 'POST'

puts '-- isolation'
first = hit(router, 'GET', '/users/1/visits').body
second = hit(router, 'GET', '/users/1/visits').body
check 'each request gets a new controller', first == 'visits 1' && second == 'visits 1'
check 'same action names in two controllers stay apart',
      hit(router, 'GET', '/books/3').body == 'book 3' && hit(router, 'GET', '/users/3').body == 'user 3'
check 'collection routes of two controllers stay apart',
      hit(router, 'GET', '/books/search').body == 'book search' && hit(router, 'GET', '/users/search').body == 'search '
books_delete = hit(router, 'DELETE', '/books/3')
check 'an action missing from the handlers is not a route',
      books_delete.status == 405 && !books_delete.headers['Allow'].include?('DELETE')
check 'a missing action is not a route', hit(router, 'POST', '/books').status == 405

slow = Kiln::Router.new.resources('/slow', SLOW_HANDLERS).seal!
results = Queue.new
workers = %w[a b c d].map do |id|
  Thread.new { results << hit(slow, 'GET', "/slow/#{id}").body }
end
workers.each(&:join)
bodies = []
bodies << results.pop until results.empty?
check 'concurrent requests do not share instance state', bodies.sort == ['slow a', 'slow b', 'slow c', 'slow d']

puts '-- options'
limited = Kiln::Router.new.resources('/users', USER_HANDLERS, only: %i[index show]).seal!
check 'only limits controller actions',
      hit(limited, 'GET', '/users/2').body == 'user 2' && hit(limited, 'POST', '/users').status == 405
scoped = Kiln::Router.new
scoped.scope('/api', wrap: ->(nxt) { ControllerGuard.new(nxt) }) do |api|
  api.get('/users/search', ->(ctx) { ControllerUsers.new(ctx).search })
  api.resources('/users', USER_HANDLERS)
end
scoped.seal!
guarded = hit(scoped, 'GET', '/api/users/search?q=x')
check 'scope prefix and wrap reach custom routes', guarded.body == 'search x' && guarded.headers['X-Guard'] == 'on'
check 'scope prefix and wrap reach controller routes', hit(scoped, 'GET', '/api/users/5').headers['X-Guard'] == 'on'
standalone = Kiln::Router.new.get('/me', ->(ctx) { ControllerUsers.new(ctx).index }).seal!
check 'controller actions work as plain route handlers', hit(standalone, 'GET', '/me').body == 'users'

puts '-- hash handlers keep working'
hashed = Kiln::Router.new
hashed.get('/tags/popular', ->(ctx) { ctx.res.text('popular') })
hashed.delete('/tags/:id/pin', ->(ctx) { ctx.res.text("unpinned #{ctx.req.params['id']}") })
tag_handlers = {
  index: ->(ctx) { ctx.res.text('tags') },
  show: ->(ctx) { ctx.res.text("tag #{ctx.req.params['id']}") }
}
hashed.resources('/tags', tag_handlers)
hashed.seal!
check 'custom collection route and hash resources', hit(hashed, 'GET', '/tags/popular').body == 'popular'
check 'custom member route and hash resources', hit(hashed, 'DELETE', '/tags/4/pin').body == 'unpinned 4'
check 'hash resources still map show', hit(hashed, 'GET', '/tags/4').body == 'tag 4'

puts '-- errors'
refuses('resource handlers must be a hash', 'resource handlers') do
  Kiln::Router.new.resources('/users', ControllerUsers)
end
refuses('only cannot select an unregistered handler', 'resource actions') do
  Kiln::Router.new.resources('/books', BOOK_HANDLERS, only: [:destroy])
end

puts '-- over a socket'
def fetch_body(port, target)
  sock = TCPSocket.new('127.0.0.1', port)
  sock.write("GET #{target} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
  read_until_closed(sock, 2.0)
ensure
  sock&.close
end

server_log = Kiln::Log.new(StringIO.new)
[[:event, 0], [:event, 2], [:base, 0]].each do |backend, handlers|
  options = { log: server_log, host: '127.0.0.1', port: 0, backend: backend }
  options[:handlers] = handlers if backend == :event
  server = Kiln::Server.new(router, nil, **options).start
  label = backend == :event ? "event, handlers: #{handlers}" : 'base'
  begin
    check "#{label}: collection route", fetch_body(server.port, '/users/search?q=io').end_with?('search io')
    check "#{label}: member route", fetch_body(server.port, '/users/9/visits').end_with?('visits 1')
    check "#{label}: show", fetch_body(server.port, '/books/2').end_with?('book 2')
  ensure
    server.shutdown(grace: 1.0)
  end
end
server_log.close
puts 'done'
