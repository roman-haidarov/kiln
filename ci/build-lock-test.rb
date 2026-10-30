require 'rbconfig'
require 'tmpdir'
require 'timeout'

helper = File.expand_path('with-build-lock.rb', __dir__)
ruby = RbConfig.ruby
Dir.mktmpdir('kiln-build-lock') do |root|
  lock = File.join(root, 'build.lock')
  first = File.join(root, 'first')
  second = File.join(root, 'second')
  marker = 'File.write(ARGV.fetch(0), "ready"); sleep 30'
  owner = Process.spawn(ruby, helper, lock, ruby, '-e', marker, first, pgroup: true)
  contender = nil
  begin
    Timeout.timeout(5) { sleep 0.01 until File.exist?(first) }
    contender = Process.spawn(ruby, helper, lock, ruby, '-e', 'File.write(ARGV.fetch(0), "ready")', second)
    sleep 0.1
    raise 'concurrent builds entered the lock' if File.exist?(second)

    Process.kill('KILL', -owner)
    Process.waitpid(owner)
    owner = nil
    Timeout.timeout(5) { Process.waitpid(contender) }
    raise 'the lock stayed held after process death' unless $?.success? && File.exist?(second)

    contender = nil
    puts 'ok build lock excludes a concurrent builder and recovers after SIGKILL'
    forged = { 'KILN_BUILD_LOCK_PATH' => lock, 'KILN_BUILD_LOCK_FD' => '999999' }
    raise 'invalid inherited lock was accepted' if system(forged, ruby, helper, '--held', lock)

    puts 'ok build lock verifies its inherited descriptor'
  ensure
    [owner, contender].compact.each do |pid|
      Process.kill('KILL', pid)
      Process.waitpid(pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
  end
end
