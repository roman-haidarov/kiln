require 'fileutils'
require 'json'
require 'open3'

baseline, candidate = ARGV.shift(2)
abort('usage: cpu_compare.rb BASELINE CANDIDATE [--runs N] [--iterations N] [--output PATH]') \
  unless baseline && candidate
runs = 3
iterations = 300_000
output = File.join(ENV.fetch('KILN_VALIDATION_DIR') { '/tmp/kiln-validation' }, 'cpu-compare.json')
until ARGV.empty?
  option = ARGV.shift
  value = ARGV.shift
  abort("missing value for #{option}") unless value
  case option
  when '--runs' then runs = Integer(value)
  when '--iterations' then iterations = Integer(value)
  when '--output' then output = value
  else abort("unknown option #{option}")
  end
end

rows = []
runs.times do |index|
  pairs = [['baseline', baseline], ['candidate', candidate]]
  pairs.reverse! if index.odd?
  pairs.each do |name, binary|
    stdout, stderr, status = Open3.capture3(binary, iterations.to_s)
    abort(stderr) unless status.success?
    values = stdout.split.to_h { |field| field.split('=', 2) }
    row = {
      name: name,
      run: index,
      iterations: Integer(values.fetch('iterations')),
      seconds: Float(values.fetch('seconds'))
    }
    rows << row
    puts JSON.generate(row)
  end
end
median = lambda do |values|
  sorted = values.sort
  middle = sorted.length / 2
  sorted.length.odd? ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2.0
end
summary = %w[baseline candidate].to_h do |name|
  times = rows.filter_map { |row| row[:seconds] / row[:iterations] * 1_000_000 if row[:name] == name }
  [name, median.call(times)]
end
FileUtils.mkdir_p(File.dirname(output))
File.write(output,
           "#{JSON.pretty_generate(workers: ENV.fetch('SPINEL_WORKERS', nil), rows: rows, median_us: summary)}\n")
puts JSON.generate(summary)
