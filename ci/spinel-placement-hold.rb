require 'ffi'

module PlacementProbe
  extend FFI::Library
  ffi_lib FFI::CURRENT_PROCESS
  attach_function :kiln_ci_worker_id, [], :long
end

def worker_id
  PlacementProbe.kiln_ci_worker_id
end

def wait_quiet(reports, mutex)
  last = -1
  stable = 0
  early = nil
  200.times do
    snapshot = mutex.synchronize { reports.dup }
    if snapshot.length == last
      stable += 1
      if stable >= 15
        early = snapshot
        break
      end
    else
      last = snapshot.length
      stable = 0
    end
    sleep 0.01
  end
  early
end

hold_path = ENV.fetch('KILN_SCHED_HOLD_ACTIVE')
marker = "#{hold_path}.wid2"
pause = Queue.new
ready = Queue.new
anchor = Thread.new do
  ready << worker_id
  pause.pop
end
home = ready.pop
raise "anchor worker #{home}" unless home == 1

reports = []
reports_mu = Mutex.new
blockers = Queue.new
pilot = Thread.new do
  reports_mu.synchronize { reports << worker_id }
  blockers.pop
end
tries = 0
until File.exist?(marker)
  tries += 1
  raise 'helper 2 did not reach the inactive hold' if tries > 200

  sleep 0.01
end
wave_n = 16
wave = Array.new(wave_n) do
  Thread.new do
    reports_mu.synchronize { reports << worker_id }
    blockers.pop
  end
end
early = wait_quiet(reports, reports_mu)
raise 'placement did not settle' unless early

File.open(hold_path, 'w') { |io| io.write('x') }
deadline = Time.now + 3
until reports_mu.synchronize { reports.length } >= wave_n + 1
  raise 'placed threads did not run' if Time.now >= deadline

  sleep 0.01
end
all = reports_mu.synchronize { reports.dup }
late = all[early.length, all.length - early.length]
early.each { |id| raise "early worker #{id}" unless id == 1 }
late.each { |id| raise "late worker #{id}" unless id == 2 }
raise "inactive worker received #{late.length}" if late.length < 8
(wave_n + 1).times { blockers << true }
pause << true
anchor.join
pilot.join
wave.each(&:join)
print "hold inactive worker received=#{late.length} early=#{early.length} ok\n"
