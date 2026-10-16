require 'stringio'
require 'kiln'

def check(label, passed)
  raise label unless passed

  puts "PASS #{label}"
end

def exposes(server, label)
  names = %i[port start shutdown connections in_flight killed late free_slots handling]
  check(label, names.all? { |name| server.respond_to?(name) })
end

def cycles(server, label)
  check(label, server.start.equal?(server) && server.port.positive? && server.shutdown(grace: 0.5).zero?)
end

def rejects(label, fragment)
  yield
  raise "#{label} accepted"
rescue ArgumentError => caught
  check(label, caught.message.include?(fragment))
end

log = Kiln::Log.new(StringIO.new)

event = Kiln::Server.new(->(ctx) { ctx.res.text('ok') }, nil, log: log, port: 0)
check('event is the default backend', event.backend == :event)
exposes(event, 'event exposes the server contract')
cycles(event, 'event starts and shuts down through the facade')

base = Kiln::Server.new(->(ctx) { ctx.res.text('ok') }, nil, log: log, port: 0, host: '127.0.0.1', backend: :base)
check('base backend is selectable', base.backend == :base)
exposes(base, 'base exposes the server contract')
cycles(base, 'base starts and shuts down through the facade')

rejects('unsupported event option is rejected', 'kill_grace') do
  Kiln::Server.new(nil, nil, log: log, port: 0, kill_grace: 1.0)
end
rejects('unknown backend is rejected', 'backend') do
  Kiln::Server.new(nil, nil, log: log, port: 0, backend: :other)
end

log.close
