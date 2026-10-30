def held_lock?(path)
  return false unless ENV['KILN_BUILD_LOCK_PATH'] == path

  number = Integer(ENV.fetch('KILN_BUILD_LOCK_FD'))
  file = File.for_fd(number, autoclose: false)
  expected = File.stat(path)
  actual = file.stat
  actual.dev == expected.dev && actual.ino == expected.ino && file.flock(File::LOCK_EX | File::LOCK_NB)
rescue KeyError, ArgumentError, IOError, SystemCallError
  false
end

if ARGV.first == '--held'
  exit(held_lock?(File.expand_path(ARGV.fetch(1))) ? 0 : 1)
end

path = File.expand_path(ARGV.shift)
raise ArgumentError, 'build command required' if ARGV.empty?

file = File.open(path, File::RDWR | File::CREAT, 0o600)
deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 600
warn "Waiting for build lock: #{path}" unless file.flock(File::LOCK_EX | File::LOCK_NB)
until file.flock(File::LOCK_EX | File::LOCK_NB)
  abort "Timed out waiting for build lock: #{path}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

  sleep 1
end
file.close_on_exec = false
ENV['KILN_BUILD_LOCK_PATH'] = path
ENV['KILN_BUILD_LOCK_FD'] = file.fileno.to_s
exec(*ARGV, close_others: false)
