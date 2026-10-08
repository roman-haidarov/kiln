require "socket"

def safe_pop
  yield
rescue ThreadError
  nil
end

port = (ENV["PORT"] || "19091").to_i
conns = (ARGV[0] || "8").to_i
seconds = (ARGV[1] || "10").to_f
stop_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
counts = Queue.new
failures = Queue.new
request = "GET /health HTTP/1.1\r\nHost: bench\r\n\r\n"
workers = conns.times.map do
  Thread.new do
    sock = nil
    done = 0
    buf = +""
    begin
      sock = TCPSocket.new("127.0.0.1", port)
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < stop_at
        sock.write(request)
        buf << sock.readpartial(4096) until buf.include?("\r\n\r\nok\n")
        buf = buf.split("\r\n\r\nok\n", 2)[1].to_s
        done += 1
      end
    rescue StandardError => e
      failures << e
    ensure
      sock.close if sock && !sock.closed?
      counts << done
    end
  end
end
workers.each(&:join)
total = 0
conns.times { total += counts.pop }
failure = safe_pop { failures.pop(true) }
raise failure if failure
puts "requests=#{total} seconds=#{seconds}"
