require 'kiln'
require 'socket'
require 'test/support'

def check(label, result)
  raise "FAIL #{label}" unless result

  puts "ok   #{label}"
end

def pending_client(port, path, extra = '')
  socket = TCPSocket.new('127.0.0.1', port)
  socket.write("GET #{path} HTTP/1.1\r\nHost: x\r\n#{extra}Connection: close\r\n\r\n")
  socket
end

entered = Queue.new
gate = Queue.new
handler = lambda do |ctx|
  if ctx.req.path == '/hold'
    entered << true
    gate.pop
  end
  ctx.res.text('ok')
end
server = Kiln::Server.new(handler, host: '127.0.0.1', port: 0, handlers: 1, request_timeout: 5,
                                  max_pending_requests: 1, max_pending_bytes: 1024)
server.start
first = second = nil
begin
  first = pending_client(server.port, '/hold')
  raise 'handler did not start' unless entered.pop(timeout: 1)

  second = pending_client(server.port, '/hold')
  wait_for { server.queued_requests == 1 }
  check 'queued requests have a bounded byte budget', server.queued_bytes.positive? && server.queued_bytes <= 1024
  excess = exchange(server.port, "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", 2)
  check 'a full dispatch queue returns 503 without another queued job',
        excess.start_with?('HTTP/1.1 503 ') && server.queued_requests == 1
  gate << true
  check 'the active request survives queue overload', read_until_closed(first, 2).end_with?('ok')
  raise 'queued handler did not start' unless entered.pop(timeout: 1)

  check 'a running handler gives back its queued budget', server.queued_requests.zero? && server.queued_bytes.zero?
  gate << true
  check 'queued work completes after capacity frees', read_until_closed(second, 2).end_with?('ok')
ensure
  3.times { gate << true }
  first&.close
  second&.close
  server.shutdown(grace: 0.2)
end

entered = Queue.new
gate = Queue.new
server = Kiln::Server.new(lambda { |ctx|
  entered << true
  gate.pop
  ctx.res.text('ok')
}, host: '127.0.0.1', port: 0, handlers: 1, request_timeout: 5,
   max_pending_requests: 8, max_pending_bytes: 256)
server.start
first = nil
begin
  first = pending_client(server.port, '/')
  raise 'byte budget handler did not start' unless entered.pop(timeout: 1)

  large = pending_client(server.port, '/', "X-Data: #{'x' * 4096}\r\n")
  raw = read_until_closed(large, 2)
  large.close
  check 'buffered headers count toward max_pending_bytes',
        raw.start_with?('HTTP/1.1 503 ') && server.queued_requests.zero? && server.queued_bytes.zero?
ensure
  gate << true
  first&.close
  server.shutdown(grace: 0.2)
end

entered = Queue.new
gate = Queue.new
server = Kiln::Server.new(lambda { |ctx|
  entered << true
  gate.pop
  ctx.res.text('ok')
}, host: '127.0.0.1', port: 0, handlers: 4, request_timeout: 5,
   max_pending_requests: 2, max_pending_bytes: 1024)
server.start
clients = []
begin
  40.times { clients << pending_client(server.port, '/') }
  Kernel.sleep 0.15
  check 'all event loops share one pending request budget',
        server.queued_requests <= 2 && server.queued_bytes <= 1024
  40.times { gate << true }
  statuses = clients.map { |socket| read_until_closed(socket, 2).byteslice(9, 3) }
  check 'overload preserves valid HTTP status responses',
        statuses.all? { |status| status == '200' || status == '503' } && statuses.include?('503')
  wait_for { server.queued_requests.zero? && server.queued_bytes.zero? }
  check 'a drained queue gives every reservation back', server.in_flight.zero?
ensure
  40.times { gate << true }
  clients.each(&:close)
  server.shutdown(grace: 0.2)
end

[[:max_pending_requests, 0], [:max_pending_bytes, 0]].each do |name, value|
  rejected = false
  begin
    Kiln::Server.new(handler, **{name => value})
  rescue ArgumentError
    rejected = true
  end
  check "#{name} validates before starting", rejected
end
