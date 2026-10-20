require 'fileutils'
require 'etc'
require 'json'
require 'socket'

baseline, candidate = ARGV.shift(2)
abort('usage: compare.rb BASELINE CANDIDATE [--seconds N] [--runs N] [--output PATH]') unless baseline && candidate
seconds = 3.0
runs = 5
output = File.join(ENV.fetch('KILN_VALIDATION_DIR', '/tmp/kiln-validation'), 'compare.json')
until ARGV.empty?
  option = ARGV.shift
  value = ARGV.shift
  abort("missing value for #{option}") unless value
  case option
  when '--seconds' then seconds = Float(value)
  when '--runs' then runs = Integer(value)
  when '--output' then output = value
  else abort("unknown option #{option}")
  end
end

proc_cpu = lambda do |pid|
  fields = File.read("/proc/#{pid}/stat").split
  (Integer(fields[13]) + Integer(fields[14])).fdiv(Etc.sysconf(Etc::SC_CLK_TCK))
end

client = lambda do |port, deadline|
  socket = TCPSocket.new('127.0.0.1', port)
  done = 0
  request = "GET /health HTTP/1.1\r\nHost: x\r\nUser-Agent: benchmark\r\nAccept: */*\r\n\r\n" * 8
  buffer = +''
  while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    socket.write(request)
    8.times do
      until (boundary = buffer.index("\r\n\r\n"))
        buffer << socket.readpartial(65_536)
      end
      header = buffer.slice!(0, boundary + 4)
      raise "unexpected response: #{header.lines.first}" unless header.start_with?('HTTP/1.1 200')

      length = Integer(header[/^content-length:\s*(\d+)/i, 1])
      buffer << socket.readpartial(65_536) while buffer.bytesize < length
      buffer.slice!(0, length)
      done += 1
    end
  end
  done
ensure
  socket&.close
end

run = lambda do |binary|
  input = IO.popen([binary], 'r+')
  line = input.gets
  line = input.gets while line && !line.start_with?('{')
  ready = JSON.parse(line)
  pid = ready.fetch('proc_pid')
  port = ready.fetch('port')
  warm_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.5
  16.times.map { Thread.new { client.call(port, warm_deadline) } }.each(&:join)
  before = proc_cpu.call(pid)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  deadline = started + seconds
  counts = 32.times.map { Thread.new { client.call(port, deadline) } }.map(&:value)
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  cpu = proc_cpu.call(pid) - before
  input.puts('stop')
  shutdown = JSON.parse(input.gets)
  input.close
  stderr = input.read
  raise stderr unless $?.success?

  {
    requests: counts.sum,
    seconds: elapsed,
    rps: counts.sum / elapsed,
    cpu_us: cpu / counts.sum * 1_000_000,
    shutdown: shutdown
  }
end

rows = []
runs.times do |index|
  pairs = if index.even?
            [['baseline', baseline], ['candidate', candidate]]
          else
            [['candidate', candidate], ['baseline', baseline]]
          end
  pairs.each do |name, binary|
    row = run.call(binary).merge(name: name, run: index)
    rows << row
    puts JSON.generate(row)
  end
end
median = lambda do |values|
  sorted = values.sort
  middle = sorted.length / 2
  sorted.length.odd? ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2.0
end
summary = %w[rps cpu_us].to_h do |key|
  values = %w[baseline candidate].to_h do |name|
    selected = rows.filter_map { |row| row[key] if row[:name] == name }
    [name, median.call(selected)]
  end
  [key, values]
end
FileUtils.mkdir_p(File.dirname(output))
File.write(output, JSON.pretty_generate(workers: ENV['SPINEL_WORKERS'], rows: rows, summary: summary) + "\n")
puts JSON.generate(summary)
