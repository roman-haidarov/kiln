path = ARGV.fetch(0)
previous_mtime = Integer(ARGV.fetch(1))
deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
last_state = nil
stable = 0

while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
  state = if File.file?(path)
            stat = File.stat(path)
            [stat.mtime.to_r * 1_000_000_000, stat.size]
          end
  if state && state[0] != previous_mtime && state[1].positive?
    if state == last_state
      stable += 1
      break if stable >= 3
    else
      last_state = state
      stable = 0
    end
  end
  sleep 0.05
end

abort("timed out waiting for allocation report: #{path}") unless stable >= 3
