require 'kiln/runtime/core'
require 'kiln/runtime/check'
require 'kiln/runtime/pool'

closed = []
lock = Mutex.new
pool = Kiln::Runtime::Pool.new(2, close: ->(value) { lock.synchronize { closed << value } }) do
  Object.new
end

held = pool.acquire
raise 'shutdown closed a borrowed connection' if pool.shutdown(timeout: 0.01).zero?
raise 'missing lease' unless pool.checked_out == 1
raise 'shutdown must reject checkout' unless begin
  pool.acquire
  false
rescue IOError
  true
end

pool.release(held)
raise 'shutdown barrier failed' unless pool.shutdown(timeout: 0.2).zero?
raise 'connection was not closed' unless closed.length == 1
raise 'pool accounting failed' unless pool.consistent? && pool.checked_out.zero?

pool2 = Kiln::Runtime::Pool.new(1, close: ->(value) { lock.synchronize { closed << value } }) { Object.new }
release = Queue.new
ready = Queue.new
worker = Thread.new do
  resource = pool2.acquire
  ready << true
  release.pop
  pool2.release(resource)
end
ready.pop
raise 'closed while another thread owns resource' if pool2.shutdown(timeout: 0.01).zero?

release << true
worker.join
raise 'pool did not drain after worker release' unless pool2.shutdown(timeout: 0.2).zero?
raise 'pool still holds a connection' unless pool2.checked_out.zero? && pool2.consistent?

pool3 = Kiln::Runtime::Pool.new(1, close: ->(value) { lock.synchronize { closed << value } }) do
  raise 'factory failed'
end
begin
  pool3.acquire
  raise 'failure was swallowed'
rescue RuntimeError => e
  raise unless e.message == 'factory failed'
end
raise 'factory failure leaked pool capacity' unless pool3.available == 1 && pool3.consistent?
raise 'failed pool did not stop' unless pool3.shutdown(timeout: 0.2).zero?

puts 'ok pool lifecycle'
