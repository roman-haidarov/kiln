require 'fileutils'
require 'etc'
require 'json'
require 'open3'
require 'socket'
require 'thread'

binary = ARGV.shift || 'build/stress_server'
idle = 10_000
seconds = 10.0
output = File.join(ENV.fetch('KILN_VALIDATION_DIR', '/tmp/kiln-validation'), 'stress.json')
until ARGV.empty?
  option = ARGV.shift
  value = ARGV.shift
  abort("missing value for #{option}") unless value
  case option
  when '--idle' then idle = Integer(value)
  when '--seconds' then seconds = Float(value)
  when '--output' then output = value
  else abort("unknown option #{option}")
  end
end

proc_stats = lambda do |pid|
  fields = File.read("/proc/#{pid}/stat").split
  ticks = Etc.sysconf(Etc::SC_CLK_TCK)
  status = File.readlines("/proc/#{pid}/status")
  rss = Integer(status.find { |line| line.start_with?('VmRSS:') }.split[1])
  targets = Dir.children("/proc/#{pid}/fd").sort.map { |fd| File.readlink("/proc/#{pid}/fd/#{fd}") }
  { cpu: (Integer(fields[13]) + Integer(fields[14])).fdiv(ticks), rss_kib: rss, fds: targets.length, fd_targets: targets }
end

server_class = Class.new do
  define_method(:initialize) do |binary, env|
    @input, @output, @wait = Open3.popen2e(env, binary)
    ready = JSON.parse(@output.gets)
    @port = ready.fetch('port')
    @pid = ready.fetch('proc_pid')
  end
  define_method(:port) { @port }
  define_method(:pid) { @pid }
  define_method(:stats) do
    @input.puts('stats')
    JSON.parse(@output.gets)
  end
  define_method(:stop) do
    @input.puts('stop')
    result = JSON.parse(@output.gets)
    status = @wait.value
    raise @output.read unless status.success?
    raise result.inspect unless result['connections'].zero? && result['handling'].zero? && result['in_flight'].zero? && result['pool_consistent'] && result['cpu_alive'].zero?
    result
  end
end

exchange = lambda do |port, path = '/health', partial = nil, read_response = true|
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  socket = TCPSocket.new('127.0.0.1', port)
  socket.write(partial || "GET #{path} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
  unless read_response
    sleep 1
    next [0, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
  end
  response = +''
  response << socket.readpartial(65_536) until response.include?("\r\n\r\n")
  header, body = response.split("\r\n\r\n", 2)
  length = Integer(header[/^content-length:\s*(\d+)/i, 1])
  body << socket.readpartial(65_536) while body.bytesize < length
  code = Integer(header.split(' ', 3)[1])
  raise "body length mismatch #{body.bytesize} != #{length}" unless body.bytesize == length
  [code, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
ensure
  socket&.close
end

result = { workers: ENV.fetch('SPINEL_WORKERS', Etc.nprocessors.to_s) }
server = server_class.new(binary, 'MAX_CONNS' => idle.to_s)
warm = 32.times.map { Thread.new { exchange.call(server.port) } }.map(&:value)
raise warm.inspect unless warm.all? { |code, _| code == 200 }
100.times do
  break if server.stats['connections'].zero?
  sleep 0.01
end
base_resources = proc_stats.call(server.pid)
clients = []
(0...idle).step(100) do |start|
  batch = [100, idle - start].min
  clients.concat(batch.times.map { Thread.new { TCPSocket.new('127.0.0.1', server.port) } }.map(&:value))
end
200.times do
  break if server.stats['connections'] == idle
  sleep 0.01
end
before = server.stats
raise before.inspect unless before['connections'] == idle
first = proc_stats.call(server.pid)
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
sleep seconds
last = proc_stats.call(server.pid)
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
result[:idle] = { clients: idle, seconds: elapsed, cpu_percent_core: 100 * (last[:cpu] - first[:cpu]) / elapsed,
                  rss_kib: last[:rss_kib], fds: last[:fds], stats: server.stats }
overflow = exchange.call(server.port)
raise overflow.inspect unless overflow[0] == 503
more = 64.times.map { Thread.new { exchange.call(server.port) } }.map(&:value)
raise more.inspect unless more.all? { |code, _| code == 503 }
result[:idle][:overflow_requests] = 65
result[:idle][:overflow_status] = overflow[0]
clients.each(&:close)
300.times do
  break if server.stats['connections'].zero?
  sleep 0.01
end
result[:idle][:after_disconnect] = server.stats
result[:idle][:resources_before] = base_resources
result[:idle][:resources_after] = proc_stats.call(server.pid)
after_targets = result[:idle][:resources_after][:fd_targets].tally
before_targets = base_resources[:fd_targets].tally
removed = before_targets.dup
after_targets.each { |target, count| removed[target] = [removed.fetch(target, 0) - count, 0].max }
removed.reject! { |_, count| count.zero? }
raise removed.inspect unless removed.empty?
added = after_targets.dup
before_targets.each { |target, count| added[target] = [added.fetch(target, 0) - count, 0].max }
added.reject! { |_, count| count.zero? }
pollers = added.delete('anon_inode:[eventpoll]') || 0
raise added.inspect unless added.all? { |target, count| target.start_with?('pipe:[') && count == 2 }
raise added.inspect unless added.length == pollers
raise after_targets.inspect unless after_targets.fetch('anon_inode:[eventpoll]', 0) <= Integer(ENV.fetch('SPINEL_WORKERS', Etc.nprocessors.to_s)) + 1
result[:idle][:lazy_runtime_fds] = { pollers: pollers, wake_pipe_pairs: added.length }
raise result[:idle][:after_disconnect].inspect unless result[:idle][:after_disconnect]['free'] == idle
result[:idle][:shutdown] = server.stop

server = server_class.new(binary, 'MAX_CONNS' => '512')
slow = 256.times.map do
  Thread.new { exchange.call(server.port, '/health', "GET /health HTTP/1.1\r\nHost: x\r\nX: ") }
end.map(&:value)
raise slow.first(5).inspect unless slow.all? { |code, _| code == 408 }
result[:slow_headers] = { clients: slow.length, codes: { '408' => slow.length }, max_seconds: slow.map(&:last).max, stats: server.stats }
sleep 0.6
work = 300.times.map { Thread.new { exchange.call(server.port) } } + 16.times.map { Thread.new { exchange.call(server.port, '/hang') } } +
       48.times.map { Thread.new { exchange.call(server.port, '/cpu') } } + 8.times.map { Thread.new { exchange.call(server.port, '/big', nil, false) } }
mixed = work.map(&:value)
health = mixed.first(300).map(&:last)
raise mixed.first(300).inspect unless mixed.first(300).all? { |code, _| code == 200 }
raise mixed[300, 16].inspect unless mixed[300, 16].all? { |code, _| code == 504 }
sleep 0.6
stats = server.stats
raise stats.inspect unless stats['connections'].zero? && stats['handling'].zero? && stats['in_flight'].zero? && stats['pool_consistent'] && stats['pool_out'].zero? && stats['pool_available'] == 16
sorted_health = health.sort
result[:mixed] = { requests: work.length, codes: mixed.map(&:first).tally.transform_keys(&:to_s),
                   health_p50_ms: sorted_health[sorted_health.length / 2] * 1000,
                   health_p99_ms: sorted_health[(sorted_health.length * 0.99).floor - 1] * 1000, stats: stats }
pending = 16.times.map { Thread.new { exchange.call(server.port, '/hang') } }
sleep 0.05
result[:mixed][:shutdown] = server.stop
pending.each { |thread| thread.join(1) }
raise result[:mixed][:shutdown].inspect unless result[:mixed][:shutdown]['free'] == 512
FileUtils.mkdir_p(File.dirname(output))
File.write(output, JSON.pretty_generate(result) + "\n")
puts JSON.pretty_generate(result)
