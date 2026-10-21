require 'kiln/db'
seen = []
moved = 0
lock = Mutex.new
threads = []
t = 0
while t < 8
  threads << Thread.new do
    mine = Kiln::DB::Native.os_thread_token
    changed = 0
    i = 0
    while i < 2000
      r, w = IO.pipe
      w.write('x')
      r.wait_readable(1.0)
      r.close
      w.close
      sleep 0.0005 if (i % 50).zero?
      changed += 1 if Kiln::DB::Native.os_thread_token != mine
      i += 1
    end
    lock.synchronize do
      seen << mine unless seen.include?(mine)
      moved += changed
    end
    nil
  end
  t += 1
end
i = 0
while i < threads.length
  threads[i].join
  i += 1
end
puts "pinning waits=16000 moved=#{moved}"
