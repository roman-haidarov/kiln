require 'kiln'
require 'stringio'
require 'test/support'

def check(label, passed)
  raise "FAIL #{label}" unless passed

  puts "ok   #{label}"
end

def start_test_server(server_object)
  server_object.start
  Kernel.sleep 0.05
end

def local_base(klass, max_conns:, &handler)
  klass.new(handler, log: Kiln::Observability::Log.new(StringIO.new), port: 0, host: '127.0.0.1',
                          max_conns: max_conns)
end

class PausedServeServer < Kiln::Server::Base
  attr_accessor :before_serve, :continue_serve

  def serve(req, slot, deadline, id, box)
    @before_serve << true
    @continue_serve.pop
    super
  end
end
handler_entered = Queue.new
paused_server = local_base(PausedServeServer, max_conns: 1) do |ctx|
  handler_entered << true
  ctx.res.text('ok')
end
paused_server.before_serve = Queue.new
paused_server.continue_serve = Queue.new
start_test_server(paused_server)
paused_client = TCPSocket.new('127.0.0.1', paused_server.port)
paused_client.write("GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
check 'request parsed before shutdown', paused_server.before_serve.pop(timeout: 1) == true
remaining = paused_server.shutdown(grace: 0)
paused_server.continue_serve << true
wait_for { paused_server.connections.zero? }
check 'grace expired: parsed request interrupted before handler starts',
      remaining == 1 && handler_entered.empty? && paused_server.in_flight.zero? && paused_server.free_slots == 1
paused_client.close

class PausedRegisterServer < Kiln::Server::Base
  attr_accessor :before_register, :continue_register

  def begin_handling(slot, deadline)
    @before_register << true
    @continue_register.pop
    super
  end
end
late_entered = Queue.new
late = local_base(PausedRegisterServer, max_conns: 1) do |ctx|
  late_entered << true
  ctx.res.text('late')
end
late.before_register = Queue.new
late.continue_register = Queue.new
start_test_server(late)
lclient = TCPSocket.new('127.0.0.1', late.port)
lclient.write("GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
late.before_register.pop(timeout: 1)
late_remaining = late.shutdown(grace: 0)
late.continue_register << true
IO.select([lclient], nil, nil, 1)
refused = begin
  lclient.readpartial(4096)
rescue IOError, SystemCallError
  ''
end
wait_for { late.connections.zero? }
check 'registration after shutdown: explicit 503 and handler not started',
      late_remaining.zero? && refused.start_with?('HTTP/1.1 503') && late_entered.empty? && late.free_slots == 1
lclient.close

graceful = local_base(PausedServeServer, max_conns: 1) { |ctx| ctx.res.text('served') }
graceful.before_serve = Queue.new
graceful.continue_serve = Queue.new
start_test_server(graceful)
gclient = TCPSocket.new('127.0.0.1', graceful.port)
gclient.write("GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
graceful.before_serve.pop(timeout: 1)
stopper = Thread.new { graceful.shutdown(grace: 2) }
Kernel.sleep 0.1
graceful.continue_serve << true
IO.select([gclient], nil, nil, 2)
served = begin
  gclient.readpartial(4096)
rescue IOError, SystemCallError
  ''
end
check 'request parsed before grace ends is served',
      served.start_with?('HTTP/1.1 200') && served.include?('served') && stopper.value.zero?
gclient.close

class GatedFinalizeServer < Kiln::Server::Base
  attr_accessor :finalize_entered, :continue_finalize

  def finalize(slot)
    @finalize_entered << true
    @continue_finalize.pop
    super
  end
end

reaper_server = GatedFinalizeServer.new(nil, log: Kiln::Observability::Log.new(StringIO.new), port: 0,
                                                  host: '127.0.0.1', max_conns: 1)
reaper_server.finalize_entered = Queue.new
reaper_server.continue_finalize = Queue.new
start_test_server(reaper_server)
rclient = TCPSocket.new('127.0.0.1', reaper_server.port)
wait_for { reaper_server.connections == 1 }
rstopper = Thread.new { reaper_server.shutdown(grace: 0) }
reaper_server.finalize_entered.pop(timeout: 2)
reaper_thread = reaper_server.instance_variable_get(:@reaper)
reaper_wake = reaper_server.instance_variable_get(:@reap_wake)
wait_for { reaper_thread.status == 'sleep' && reaper_wake.empty? }
reaper_server.continue_finalize << true
shutdown_result = rstopper.value
check 'shutdown wakes reaper after last connection is removed',
      shutdown_result.zero? && !reaper_thread.alive? && reaper_server.connections.zero?
restarted = begin
  start_test_server(reaper_server)
  true
rescue Errno::EADDRINUSE
  false
end
check 'server can restart after shutdown', restarted
reaper_server.shutdown(grace: 0)
rclient.close

class GatedWriteServer < Kiln::Server::Base
  BODY_SIZE = 128 * 1024
  attr_accessor :write_entered, :continue_write

  def write_all(sock, data, deadline, body = EMPTY_BODY)
    if body.bytesize == BODY_SIZE
      @write_entered << true
      @continue_write.pop
    end
    super
  end
end

big_body = 'w' * GatedWriteServer::BODY_SIZE
wsrv = local_base(GatedWriteServer, max_conns: 2) { |ctx| ctx.res.text(big_body) }
write_entered = Queue.new
continue_write = Queue.new
wsrv.write_entered = write_entered
wsrv.continue_write = continue_write
start_test_server(wsrv)
wclient = TCPSocket.new('127.0.0.1', wsrv.port)
wclient.write("GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
check 'server enters response writing', write_entered.pop(timeout: 3) == true
wstop = Thread.new do
  wsrv.shutdown(grace: 5)
  wsrv.connections
end
wait_for { wsrv.instance_variable_get(:@draining) }
received = (+'').b
response_reader = Thread.new do
  loop { received << wclient.readpartial(65_536) }
rescue IOError, SystemCallError
  nil
end
continue_write << true
read_deadline = Kiln::Runtime.now + 3
Kernel.sleep 0.01 while response_reader.alive? && Kiln::Runtime.now < read_deadline
if response_reader.alive?
  wclient.close
  response_reader.kill
end
response_reader.join
open_at_return = wstop.value
unless open_at_return.zero? && received.bytesize > big_body.bytesize && received.end_with?('www'.b)
  raise "shutdown writing check: connections=#{open_at_return} " \
        "bytes=#{received.bytesize} complete=#{received.end_with?('www'.b)}"
end

check 'shutdown returns only after a response being written is finished',
      open_at_return.zero? && received.bytesize > big_body.bytesize && received.end_with?('www'.b)
wclient.close

huge = 'y' * (32 * 1024 * 1024)
stuck_srv = local_base(Kiln::Server::Base, max_conns: 2) { |ctx| ctx.res.text(huge) }
start_test_server(stuck_srv)
stuck_client = TCPSocket.new('127.0.0.1', stuck_srv.port)
stuck_client.write("GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
Kernel.sleep 0.3
left_work = stuck_srv.shutdown(grace: 0)
freed = begin
  wait_for { stuck_srv.connections.zero? }
  true
rescue RuntimeError
  false
end
check 'grace expired: shutdown reports unfinished writing and stops the writer', left_work == 1 && freed
stuck_client.close

class CountingServer < Kiln::Server::Base
  attr_accessor :max_batch

  def write_all(sock, data, deadline, body = EMPTY_BODY)
    count = data.scan('HTTP/1.1 200'.b).size
    @max_batch = count if count > @max_batch
    super
  end
end
counted = local_base(CountingServer, max_conns: 2) { |ctx| ctx.res.text('ok') }
counted.max_batch = 0
start_test_server(counted)
pclient = TCPSocket.new('127.0.0.1', counted.port)
pipeline = (+'').b
39.times { pipeline << "GET / HTTP/1.1\r\nHost: x\r\n\r\n".b }
pipeline << "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".b
pclient.write(pipeline)
replies = read_until_closed(pclient, 5)
check 'pipelined batches respect the 16-response limit',
      replies.scan('HTTP/1.1 200'.b).size == 40 && counted.max_batch <= 16 && counted.max_batch > 1
pclient.close
counted.shutdown(grace: 0)
