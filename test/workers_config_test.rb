require 'kiln/runtime/parallelism'
require 'tmpdir'

original = ENV['KILN_WORKERS']
begin
  %w[0 -1 invalid 99999999 2junk].each do |value|
    ENV['KILN_WORKERS'] = value
    rejected = false
    begin
      Kiln::Runtime.workers
    rescue ArgumentError => error
      rejected = error.message.include?('KILN_WORKERS')
    end
    raise "invalid workers accepted: #{value}" unless rejected
  end
ensure
  original ? ENV['KILN_WORKERS'] = original : ENV.delete('KILN_WORKERS')
end
puts 'ok   invalid KILN_WORKERS raises without terminating the process'

root = Dir.mktmpdir('kiln-production-scheduler')
path = File.join(root, 'missing-gate')
ENV['KILN_SCHED_HOLD_ACTIVE'] = path
ENV['KILN_SCHED_HOLD_MIN_WID'] = '1'
begin
  count = Kiln::Runtime.workers
  value = Thread.new { 42 }.value
  raise 'scheduler failed after configuration error' unless value == 42 && Kiln::Runtime.workers == count
  raise 'production scheduler contains the FIFO test hook' unless Dir.children(root).empty?

  puts 'ok   production runtime ignores scheduler test hook variables'
ensure
  ENV.delete('KILN_SCHED_HOLD_ACTIVE')
  ENV.delete('KILN_SCHED_HOLD_MIN_WID')
  Dir.children(root).each { |name| File.delete(File.join(root, name)) }
  Dir.rmdir(root)
end
