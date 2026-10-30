require 'kiln'
require 'kiln/db'
require 'test/support'

workers = Kiln::Runtime.workers
raise 'application worker count' unless workers.positive?
if ENV['KILN_WORKERS']
  raise 'KILN_WORKERS must count application workers' unless workers == Integer(ENV.fetch('KILN_WORKERS'))
end
pool = Kiln::DB::Pool.new { raise 'the unused pool must stay lazy' }
raise 'automatic pool capacity' unless pool.size == workers * 16 && pool.opened.zero?
pool.close
explicit = Kiln::DB::Pool.new(3) { raise 'unused' }
raise 'explicit pool capacity' unless explicit.size == 3
explicit.close
puts 'ok application workers and lazy pool defaults'

started = Queue.new
release = Queue.new
handler = lambda do |ctx|
  started << true
  release.pop
  ctx.res.text('ok')
end
server = Kiln::Server.new(handler, host: '127.0.0.1', port: 0, request_timeout: 10)
server.start
clients = []
responses = Queue.new
begin
  8.times do
    clients << Thread.new do
      responses << exchange(server.port, "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", 10)
    end
  end
  8.times do
    raise 'default handlers serialize waiting requests' unless started.pop(timeout: 3)
  end
  8.times { release << true }
  clients.each(&:join)
  8.times do
    reply = responses.pop
    raise 'default handler response' unless reply.start_with?('HTTP/1.1 200 ') && reply.end_with?('ok')
  end
  puts 'ok default event handlers overlap eight waiting requests'
ensure
  8.times { release << true }
  clients.each { |thread| thread.kill if thread.alive? }
  server.shutdown(grace: 0.5)
end
