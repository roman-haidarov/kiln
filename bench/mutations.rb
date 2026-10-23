require 'fileutils'
require 'find'
require 'json'
require 'open3'
require 'tmpdir'
require 'timeout'

project = File.expand_path('..', __dir__)
compiler = ENV.fetch('SPINEL') { 'spinel' }
timeout_seconds = Integer(ENV.fetch('MUTATION_TIMEOUT') { '30' })
result_path = File.join(ENV.fetch('KILN_VALIDATION_DIR') { '/tmp/kiln-validation' }, 'mutations.json')
FileUtils.mkdir_p(File.dirname(result_path))
mutations = [
  ['stale_double_close', 'kiln/runtime/pool.rb', 'test/lifecycle_test.rb', 'held.quarantine = true', 'held.quarantine = false',
   'FAIL kill during stale resource close does not close twice'],
  ['expired_cpu_start', 'kiln/runtime/cpu_pool.rb', 'test/lifecycle_test.rb', 'if Kiln::Runtime.now >= job.expires', 'if false',
   'wait timeout'],
  ['connection_cleanup_lock', 'kiln/server/base/server.rb', 'test/lifecycle_test.rb',
   "def finish(slot)\n          @finished << slot",
   "def finish(slot)\n          @lock.synchronize { @finished << slot }",
   'FAIL connection ensure completes while server mutex is held'],
  ['header_overlap', 'kiln/server/base/request.rb', 'test/server_test.rb', 'from = [buf.size - marker_size + 1, 0].max',
   'from = buf.size', 'FAIL header terminator split across three reads is found'],
  ['chunk_extensions', 'kiln/server/base/request.rb', 'bench/chunk_extension_probe.rb',
   'size = HTTP::Native.kiln_chunk_size(line, line.bytesize, @max_body - body.bytesize)',
   'size = line == "3;".b ? 3 : HTTP::Native.kiln_chunk_size(line, line.bytesize, @max_body - body.bytesize)',
   'FAIL invalid extension "3;" -> 400'],
  ['spawn_after_close', 'kiln/runtime/cpu_pool.rb', 'test/lifecycle_test.rb', 'return false if @closed', 'nil',
   'FAIL replacement after close does not call Thread.new'],
  ['constructor_leak', 'kiln/runtime/cpu_pool.rb', 'test/lifecycle_test.rb', 'shutdown(grace: 0) unless initialized',
   'nil',
   'FAIL constructor failure closes workers already started'],
  ['batch_handoff', 'kiln/runtime/pool.rb', 'test/lifecycle_test.rb',
   'wake_idle if held.granted && (!@idle.empty? || @open < @size)', 'nil',
   'FAIL batched returns wake all waiters without polling']
]
selected = ENV.fetch('MUTATIONS') { '' }.split(',')
rows = []
mutations.each do |name, relative, test, old, replacement, expected|
  next unless selected.empty? || selected.include?(name)

  Dir.mktmpdir("kiln-mutant-#{name}-") do |temporary|
    destination = File.join(temporary, name)
    FileUtils.mkdir_p(destination)
    Find.find(project) do |path|
      relative_path = path.delete_prefix("#{project}/")
      next if relative_path.empty?

      if File.directory?(path)
        if %w[build .git __pycache__].include?(File.basename(path))
          Find.prune
          next
        end
        FileUtils.mkdir_p(File.join(destination, relative_path))
      else
        target_path = File.join(destination, relative_path)
        FileUtils.mkdir_p(File.dirname(target_path))
        FileUtils.cp(path, target_path)
      end
    end
    target = File.join(destination, relative)
    source = File.read(target)
    if old == 'stale_quarantine'
      pattern = /(?m)^([ \t]*)quarantine = true\n\1entry = nil$/
      count = source.scan(pattern).length
      source = source.sub(pattern) { "#{Regexp.last_match(1)}nil" }
    else
      count = source.scan(old).length
      source = source.gsub(old, replacement)
    end
    raise "#{name}: expected one replacement, got #{count}" unless count == 1

    File.write(target, source)
    links_output, error, status = Open3.capture3('./ext/build.sh', chdir: destination)
    raise error unless status.success?

    links = links_output.split
    _build_out, build_error, build_status = Open3.capture3(
      compiler, *links, '-I', '.', test, '-o', 'build/mutant', chdir: destination
    )
    raise build_error unless build_status.success?

    begin
      stdout = stderr = nil
      exit_status = nil
      Timeout.timeout(timeout_seconds) do
        stdout, stderr, status = Open3.capture3({ 'SPINEL_WORKERS' => '1' }, 'build/mutant', chdir: destination)
        exit_status = status.exitstatus
      end
      detected = exit_status != 0 && (stdout.include?(expected) || stderr.include?(expected))
      row = { name: name, detected: detected, exit_code: exit_status, expected: expected,
              stderr: stderr[-1500..], last_output: stdout.lines.last(3).map(&:chomp) }
    rescue Timeout::Error
      row = { name: name, detected: false, timeout: true, expected: expected }
    end
    rows << row
    puts JSON.generate(row)
  end
end
previous = File.file?(result_path) ? JSON.parse(File.read(result_path)) : []
merged = previous.to_h { |row| [row.fetch('name'), row] }
rows.each { |row| merged[row.fetch(:name)] = row }
File.write(result_path, "#{JSON.pretty_generate(merged.values)}\n")
abort('mutation was not detected') unless rows.all? { |row| row[:detected] }
