require 'socket'
require 'timeout'
require 'open3'
require 'json'
require 'etc'
require 'fileutils'

$stdout.sync = true
binary = File.expand_path(ARGV.fetch(0))
output = File.expand_path(ARGV.fetch(1))
FileUtils.mkdir_p(output)
workers = ENV.fetch('WORKERS', '1,2,4').split(',').map { |n| Integer(n) }
modes = ENV.fetch('MODES', 'base,lanes').split(',')
paths = ENV.fetch('PATHS', 'hello,cpu,io').split(',')
rounds = Integer(ENV.fetch('ROUNDS', '3'))
connections = Integer(ENV.fetch('CONNECTIONS', '512'))
threads = Integer(ENV.fetch('THREADS', '4'))
duration = Integer(ENV.fetch('DURATION', '10'))
port = Integer(ENV.fetch('PORT', '18421'))
hz = Etc.sysconf(Etc::SC_CLK_TCK).to_f
rows = []
raise 'invalid worker list' if workers.empty? || workers.any? { |count| count < 1 }
raise 'invalid benchmark limits' unless rounds.positive? && connections.positive? && duration.positive?
raise 'invalid modes' unless !modes.empty? && (modes - %w[base lanes inline]).empty?
raise 'invalid paths' unless !paths.empty? && (paths - %w[hello cpu io db]).empty?
raise 'invalid client threads' unless threads.positive? && threads <= connections
needed_fds = (connections * 2) + (workers.max * 64) + 256
soft_fds, hard_fds = Process.getrlimit(:NOFILE)
raise 'benchmark needs a higher hard fd limit' if hard_fds < needed_fds

Process.setrlimit(:NOFILE, needed_fds, hard_fds) if soft_fds < needed_fds

def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

def cpu_seconds(pid, hz)
  if File.file?("/proc/#{pid}/stat")
    fields = File.read("/proc/#{pid}/stat").rpartition(') ').last.split
    (fields[11].to_i + fields[12].to_i) / hz
  else
    value = IO.popen(['ps', '-p', pid.to_s, '-o', 'time='], &:read).strip
    parts = value.split(':').map(&:to_f)
    parts.reverse.each_with_index.sum { |part, index| part * (60**index) }
  end
end

def family_cpu_seconds(pid, hz)
  return nil if pid.nil? || !File.directory?('/proc')

  family = [Integer(pid)]
  parents = {}
  Dir.glob('/proc/[0-9]*/stat').each do |path|
    fields = File.read(path).rpartition(') ').last.split
    parents[path.split('/')[2].to_i] = fields[1].to_i
  rescue Errno::ENOENT, Errno::ESRCH
    next
  end
  index = 0
  while index < family.size
    parents.each { |child, parent| family << child if parent == family[index] }
    index += 1
  end
  family.sum { |child| cpu_seconds(child, hz) }
rescue Errno::ENOENT, Errno::ESRCH
  nil
end

def stop_server(pid)
  Process.kill('TERM', pid)
  Timeout.timeout(8) { Process.waitpid(pid) }
rescue Errno::ESRCH, Errno::ECHILD
  nil
rescue Timeout::Error
  Process.kill('KILL', pid)
  Process.waitpid(pid)
  raise 'server failed to stop gracefully'
end

modes.each do |mode|
  workers.each do |count|
    tag = "#{mode}-#{count}"
    log = File.join(output, "#{tag}.server.log")
    env = { 'KILN_WORKERS' => count.to_s, 'SPINEL_WORKERS' => nil, 'KILN_MODE' => mode, 'PORT' => port.to_s,
            'SPINEL_GC_STATS' => ENV['BENCH_GC_STATS'], 'SPINEL_SCHED_STATS' => ENV['BENCH_SCHED_STATS'],
            'SPINEL_ALLOC_REPORT' => nil, 'SPINEL_ALLOC_SITES' => nil }
    pid = Process.spawn(env, binary, out: log, err: [:child, :out])
    begin
      ready = nil
      Timeout.timeout(20) do
        until ready
          raise "server exited: #{log}" if Process.waitpid(pid, Process::WNOHANG)

          ready = File.read(log)[/^READY (\d+) (\d+) .+$/, 0]
          sleep 0.02 unless ready
        end
      end
      proc_pid = ready.split[2].to_i
      paths.each do |path|
        url = "http://127.0.0.1:#{port}/#{path}"
        check = TCPSocket.new('127.0.0.1', port)
        check.write("GET /#{path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        reply = Timeout.timeout(5) { check.read }
        check.close
        body = reply.split("\r\n\r\n", 2).last
        valid = body == 'ok'
        if path == 'cpu'
          seed, value = body.split.map { |part| Integer(part) }
          expected = seed
          30_000.times { expected = ((expected * 1_664_525) + 1_013_904_223) & 0x7fffffff }
          valid = value == expected
        end
        raise "invalid response for #{tag}/#{path}: #{reply}" unless reply.start_with?('HTTP/1.1 200 ') && valid

        warm, status = Open3.capture2e('wrk', "-t#{threads}", "-c#{connections}", '-d2s', url)
        File.write(File.join(output, "#{tag}-#{path}.warmup.txt"), warm)
        raise 'warmup failed' unless status.success? && !warm.include?('Non-2xx or 3xx responses:') && !warm.include?('Socket errors:')

        rounds.times do |round|
          before = cpu_seconds(proc_pid, hz)
          database_before = family_cpu_seconds(ENV['DB_PROCESS_ID'], hz)
          child_before = Process.times
          started = monotonic
          raw, status = Open3.capture2e('wrk', "-t#{threads}", "-c#{connections}", "-d#{duration}s", '--latency', url)
          elapsed = monotonic - started
          cpu = cpu_seconds(proc_pid, hz) - before
          child_after = Process.times
          client_cpu = child_after.cutime + child_after.cstime - child_before.cutime - child_before.cstime
          database_after = family_cpu_seconds(ENV['DB_PROCESS_ID'], hz)
          database_cpu = database_before && database_after ? database_after - database_before : nil
          File.write(File.join(output, "#{tag}-#{path}-#{round + 1}.txt"), raw)
          raise "wrk failed: #{tag}/#{path}" unless status.success?
          raise "response errors: #{tag}/#{path}" if raw.include?('Non-2xx or 3xx responses:') || raw.include?('Socket errors:')

          rps = Float(raw[/Requests\/sec:\s+(\S+)/, 1])
          total = Integer(raw[/(\d+) requests in /, 1])
          row = { mode: mode, workers: count, path: path, round: round + 1, rps: rps,
                  p99: raw[/^\s+99%\s+(\S+)/, 1], cpu_percent: (cpu / elapsed * 100).round(2),
                  client_cpu_percent: (client_cpu / elapsed * 100).round(2),
                  database_cpu_percent: database_cpu ? (database_cpu / elapsed * 100).round(2) : nil,
                  cpu_us_per_request: (cpu * 1_000_000 / total).round(2), connections: connections, client_threads: threads, duration_seconds: elapsed.round(3),
                  pool: ready[/pool=(\d+)/, 1].to_i, loops: ready[/loops=(\d+)/, 1] ? ready[/loops=(\d+)/, 1].to_i : (mode == 'base' ? 0 : 1), binary: binary, raw: raw }
          rows << row
          File.write(File.join(output, 'results.json'), JSON.pretty_generate(rows) + "\n")
          puts row.reject { |key, _| key == :raw }.to_json
        end
      end
    ensure
      stop_server(pid)
    end
  end
end
puts "Results: #{output}"
