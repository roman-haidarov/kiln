require 'kiln/db'

Thread.current
Thread.report_on_exception = false
raise 'configure' unless Kiln::DB::Native.configure == Kiln::DB::Native::OK

def dns_handle
  handle, error = Kiln::DB::Native.open_conn(Kiln::DB::Native::KIND_PG, 1, 1)
  raise 'create' unless handle.positive? && error == Kiln::DB::Native::OK

  handle
end

def dns_submit(handle)
  out = [0, 0, 0]
  deadline = Kiln::DB::Native.now_ms + 5000
  loop do
    rc = Kiln::DB::Native.kiln_db_conn_dns_submit(handle, 1, 1, 'localhost', 9, out, 3)
    return out if rc == Kiln::DB::Native::OK
    raise 'submit' unless rc == Kiln::DB::Native::CAPACITY && Kiln::DB::Native.now_ms < deadline

    sleep 0.005
  end
end

def dns_close(handle)
  out = Array.new(8, 0)
  rc = Kiln::DB::Native.kiln_db_step(handle, 1, 1, Kiln::DB::Native::OP_CLOSE, 0, 0, out, 8)
  raise 'close' unless rc == Kiln::DB::Native::OK
end

%w[raise kill].each do |kind|
  32.times do
    ready = Queue.new
    wait = Queue.new
    thread = Thread.new do
      handle = dns_handle
      begin
        dns_submit(handle)
        ready << true
        wait.pop
      ensure
        dns_close(handle)
      end
    end
    ready.pop
    if kind == 'kill'
      thread.kill
      thread.join
    else
      thread.raise(RuntimeError, 'dns-stop')
      begin
        thread.join
      rescue RuntimeError => error
        raise unless error.message == 'dns-stop'
      end
    end
  end
  handle = dns_handle
  resolved = Kiln::DB::Native.pg_hostaddr(handle, 'localhost', Kiln::DB::Native.now_ms + 5000)
  raise 'resolve after interrupt' if resolved.empty?

  dns_close(handle)
  puts "dns #{kind} cleanup ok"
end

handle = dns_handle
first = dns_submit(handle)
state = [Kiln::DB::Native::BUSY]
while state[0] == Kiln::DB::Native::BUSY
  Kiln::DB::Native.kiln_db_conn_dns_take(handle, 1, 1, first[0], state, 1)
  sleep 0.001 if state[0] == Kiln::DB::Native::BUSY
end
raise 'take' unless state[0] == Kiln::DB::Native::OK

second = dns_submit(handle)
Kiln::DB::Native.kiln_db_conn_dns_take(handle, 1, 1, first[0], state, 1)
raise 'stale generation' unless state[0] == Kiln::DB::Native::STALE

state[0] = Kiln::DB::Native::BUSY
while state[0] == Kiln::DB::Native::BUSY
  Kiln::DB::Native.kiln_db_conn_dns_take(handle, 1, 1, second[0], state, 1)
  sleep 0.001 if state[0] == Kiln::DB::Native::BUSY
end
raise 'new generation remains valid' unless state[0] == Kiln::DB::Native::OK

dns_close(handle)
puts 'dns generation ok'
puts 'ok dns interrupt'
