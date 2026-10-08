require 'kiln'
require 'socket'

def read_until_closed(sock, seconds)
  data = (+'').b
  reader = Thread.new do
    Thread.current.report_on_exception = false
    loop do
      chunk = begin
        sock.readpartial(65_536)
      rescue IOError, SystemCallError
        nil
      end
      break unless chunk

      data << chunk
    end
  end
  deadline = Kiln.now + seconds
  Kernel.sleep 0.01 while reader.alive? && Kiln.now < deadline
  if reader.alive?
    begin
      sock.close
    rescue IOError, SystemCallError
      nil
    end
    reader.kill
    cleanup_deadline = Kiln.now + 0.5
    Kernel.sleep 0.001 while reader.alive? && Kiln.now < cleanup_deadline
  end
  data
end

def wait_for
  limit = Kiln.now + 3
  until yield
    raise 'wait timeout' if Kiln.now >= limit

    Kernel.sleep 0.01
  end
end

def run_lost(pool, timeout: 5, &work)
  Thread.new do
    pool.run(timeout: timeout, &work)
  rescue Kiln::WorkerLost
    :lost
  end
end

def pool_holds?(pool, available: :skip, quarantined: :skip, failures: :skip, closing: :skip, abandoned: :skip)
  return false unless pool.consistent?
  return false if available != :skip && pool.available != available
  return false if quarantined != :skip && pool.quarantined != quarantined
  return false if failures != :skip && pool.close_failures != failures
  return false if closing != :skip && pool.closing != closing
  return false if abandoned != :skip && pool.close_abandoned != abandoned

  true
end

def exchange(port, data, seconds = 2.0)
  sock = TCPSocket.new('127.0.0.1', port)
  sock.write(data)
  out = (+'').b
  limit = Kiln.now + seconds
  while Kiln.now < limit
    ready, = IO.select([sock], nil, nil, limit - Kiln.now)
    break unless ready

    chunk = begin
      sock.read_nonblock(65_536, exception: false)
    rescue IOError, SystemCallError
      nil
    end
    break if chunk.nil?
    next if chunk == :wait_readable

    out << chunk
  end
  sock.close
  out
end

def collect_until(sock, seconds)
  out = (+'').b
  limit = Kiln.now + seconds
  until yield(out) || Kiln.now > limit
    IO.select([sock], nil, nil, 0.2)
    chunk = sock.read_nonblock(4096, exception: false)
    out << chunk if chunk.is_a?(String)
  end
  out
end
