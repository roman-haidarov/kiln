require 'kiln/db'
require 'test/db/support'

Thread.current
Thread.report_on_exception = false

def need(label, cond)
  return if cond

  print "FAILED #{label}\n"
  raise label
end

def park
  read_io, write_io = IO.pipe
  before = fd_count
  thread = Thread.new do
    Kiln::DB::Native.wait_once(read_io.fileno, Kiln::DB::Native::READY_READ, 30)
  end
  deadline = Time.now + 2
  until thread.status == 'sleep' || Time.now >= deadline
    sleep 0.005
  end
  need('wait parked', thread.status == 'sleep' && before >= 0)
  [thread, before, read_io, write_io]
end

def release(thread, before, read_io, write_io, kind)
  after = fd_count
  read_io.close
  write_io.close
  thread.join if thread.alive?
  need("#{kind} releases the wait (#{before}->#{after})", after <= before)
end

def interrupt(thread, kind)
  if kind == 'kill'
    thread.kill
    thread.join
    return
  end
  thread.raise(RuntimeError, 'stop')
  begin
    thread.join
  rescue RuntimeError
  end
end

read_io, write_io = IO.pipe
Kiln::DB::Native.wait_once(read_io.fileno, Kiln::DB::Native::READY_READ, 0.01)
read_io.close
write_io.close
%w[raise kill].each do |kind|
  thread, _count, read_end, write_end = park
  interrupt(thread, kind)
  read_end.close
  write_end.close
end
read_io, write_io = IO.pipe
Kiln::DB::Native.wait_once(read_io.fileno, Kiln::DB::Native::READY_READ, 0.05)
read_io.close
write_io.close

read_io, write_io = IO.pipe
before = fd_count
ready = Kiln::DB::Native.wait_once(read_io.fileno, Kiln::DB::Native::READY_READ, 0.05)
after = fd_count
read_io.close
write_io.close
need('timeout result', ready == Kiln::DB::Native::READY_TIMEOUT)
need("timeout releases the wait (#{before}->#{after})", after <= before && before >= 0)
print "timeout close ok\n"

8.times do
  thread, count, read_end, write_end = park
  thread.raise(RuntimeError, 'stop')
  begin
    thread.join
  rescue RuntimeError
  end
  release(thread, count, read_end, write_end, 'raise')
end
print "raise close ok\n"

8.times do
  thread, count, read_end, write_end = park
  thread.kill
  thread.join
  release(thread, count, read_end, write_end, 'kill')
end
print "kill close ok\n"
print "ok wait interrupt\n"
