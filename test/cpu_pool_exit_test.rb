require 'kiln'

# An exit inside a CPU task ends the program, as an exit in any thread does in
# CRuby (and in Spinel since 9866dce6): CpuPool answers the caller with
# WorkerLost and re-raises the SystemExit, which reaches the main thread.
# This must stay the last thing the file does.
at_exit { puts 'at_exit ran' }
pool = Kiln::Runtime::CpuPool.new(1)
begin
  begin
    pool.run(timeout: 2) { exit }
  rescue Kiln::Runtime::WorkerLost
    nil
  end
  Kernel.sleep 2
  puts 'FAIL process survived exit in a cpu task'
ensure
  puts 'main ensure ran'
end
