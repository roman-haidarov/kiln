require 'csv'
require 'set'

root = ARGV.fetch(0)
memory = ARGV[1] == '1'
metadata = File.readlines(File.join(root, 'meta.txt'), chomp: true).filter_map do |line|
  line.split('=', 2) if line.include?('=')
end.to_h
window_seconds = Float(metadata.fetch('duration').delete_suffix('s'))
patterns = {
  'wrk' => %r{^Requests/sec:\s+([\d.]+)},
  'k6' => %r{^\s*http_reqs[^:]*:\s+\S+\s+([\d.]+)/s},
  'oha' => %r{^  Requests/sec:\s+([\d.]+)}
}
durations = { 'ns' => 0.000001, 'us' => 0.001, 'µs' => 0.001, 'ms' => 1.0, 's' => 1000.0 }

milliseconds = lambda do |value|
  normalized = value.delete(' ')
  match = /\A([\d.]+)(ns|us|µs|ms|s)\z/.match(normalized)
  raise "unknown latency value #{value}" unless match

  Float(match[1]) * durations.fetch(match[2])
end

measurements = lambda do |client, text|
  rps = patterns.fetch(client).match(text)
  raise "no requests per second found for #{client}" unless rps

  requests = nil
  total = nil

  if client == 'wrk'
    average = /^\s+Latency\s+([\d.]+(?:ns|us|µs|ms|s))/.match(text)
    tail = /^\s+99%\s+([\d.]+(?:ns|us|µs|ms|s))/.match(text)
    requests = /^\s*(\d+) requests in/.match(text)
    estimated = false
    percentile = 99
  elsif client == 'k6'
    average = /^\s*http_req_duration[^:]*:.*?avg=([\d.]+(?:ns|us|µs|ms|s))/.match(text)
    tail = /^\s*http_req_duration[^:]*:.*?p\(95\)=([\d.]+(?:ns|us|µs|ms|s))/.match(text)
    requests = /^\s*http_reqs[^:]*:\s+([\d.]+)/.match(text)
    estimated = false
    percentile = 95
  else
    average = /^  Average:\s+([\d.]+\s*(?:ns|us|µs|ms|s))/.match(text)
    tail = /^  95\.00% in ([\d.]+\s*(?:ns|us|µs|ms|s))/.match(text)
    total = /^  Total:\s+([\d.]+\s*(?:ns|us|µs|ms|s))/.match(text)
    estimated = true
    percentile = 95
  end
  raise "latency summary missing for #{client}" unless average && tail

  request_count = requests ? Integer(requests[1]) : (Float(rps[1]) * milliseconds.call(total[1]) / 1000).round
  raise "request count missing for #{client}" unless request_count.positive?

  [Float(rps[1]), milliseconds.call(average[1]), percentile, milliseconds.call(tail[1]), request_count, estimated]
end

rows = Dir.glob(File.join(root, '*-r[0-9]*.txt')).sort.filter_map do |path|
  match = /\A(inline|lanes|server)-([a-z-]+)-(wrk|k6|oha)-r(\d+)\.txt\z/.match(File.basename(path))
  next unless match

  mode, feature, client, round_number = match.captures
  values = measurements.call(client, File.read(path))
  label = "#{mode}-#{feature}-#{client}-r#{round_number}"
  cpu_before_path = File.join(root, "#{label}.cpu.before")
  cpu_after_path = File.join(root, "#{label}.cpu.after")
  cpu_before = File.file?(cpu_before_path) ? File.read(cpu_before_path).strip : ''
  cpu_after = File.file?(cpu_after_path) ? File.read(cpu_after_path).strip : ''
  cpu_seconds = cpu_before.empty? || cpu_after.empty? ? '' : (Float(cpu_after) - Float(cpu_before)).round(6)
  cpu_per_request = cpu_seconds == '' ? '' : (cpu_seconds / values[4] * 1_000_000).round(4)
  [mode, feature, client, Integer(round_number), *values, cpu_seconds, cpu_per_request]
end

write_tsv = lambda do |path, columns, data|
  CSV.open(path, 'w', col_sep: "\t", row_sep: "\n") do |csv|
    csv << columns
    data.each { |row| csv << row }
  end
end

write_tsv.call(File.join(root, 'summary.tsv'),
               %w[mode feature client round requests_per_second average_latency_ms tail_percentile tail_latency_ms
                  requests request_count_estimated cpu_seconds cpu_us_per_request], rows)
groups = rows.group_by { |row| row.first(3) }
median_rows = groups.sort.map do |key, samples|
  sorted_rps = samples.map { |row| row[4] }.sort
  sorted_average = samples.map { |row| row[5] }.sort
  sorted_tail = samples.map { |row| row[7] }.sort
  sorted_cpu = samples.filter_map { |row| row[11] unless row[11] == '' }.sort
  median = lambda do |values|
    middle = values.length / 2
    values.length.odd? ? values[middle] : (values[middle - 1] + values[middle]) / 2.0
  end
  median_cpu = sorted_cpu.empty? ? '' : median.call(sorted_cpu).round(4)
  [*key, median.call(sorted_rps).round(2), median.call(sorted_average).round(4), samples.first[6],
   median.call(sorted_tail).round(4), median_cpu]
end
write_tsv.call(File.join(root, 'median.tsv'),
               %w[mode feature client requests_per_second_median average_latency_ms_median tail_percentile
                  tail_latency_ms_median cpu_us_per_request_median],
               median_rows)

gc_stats = lambda do |path|
  line = File.file?(path) ? File.read(path).strip : ''
  match = %r{
    ^\[gc\]\s(\d+)\scollections\s\((\d+)\sfull\)\sin\s([\d.]+)s\sof\s
    ([\d.]+)s\swall\s\(([\d.]+)%\),\s([\d.]+)ms\savg;\slive\s([\d.]+)\sMB\sobj\s\+\s([\d.]+)\sMB\sstr;
  }x.match(line)
  [line, match && match.captures.map { |value| Float(value) }]
end

gc_rows = []
resident_rows = []
rows.each do |row|
  mode, feature, client, round_number = row.first(4)
  label = "#{mode}-#{feature}-#{client}-r#{round_number}"
  before_line, before = gc_stats.call(File.join(root, "#{label}.gc.before"))
  after_line, after = gc_stats.call(File.join(root, "#{label}.gc.after"))
  updated = !after_line.empty? && after_line != before_line
  if before && after
    gc_delta = [(after[0] - before[0]).to_i, (after[1] - before[1]).to_i, (after[2] - before[2]).round(6)]
    live_obj, live_str = after[6], after[7]
  else
    gc_delta = ['', '', '']
    live_obj, live_str = ['', '']
  end
  gc_share = gc_delta[2] == '' ? '' : (gc_delta[2] / window_seconds * 100).round(4)
  gc_rows << [mode, feature, client, round_number, updated ? 1 : 0, *gc_delta, gc_share, live_obj, live_str]
  next unless memory

  rss_before = File.read(File.join(root, "#{label}.rss.before")).strip
  rss_after = File.read(File.join(root, "#{label}.rss.after")).strip
  before_kb = rss_before.empty? ? '' : Integer(rss_before)
  after_kb = rss_after.empty? ? '' : Integer(rss_after)
  change_kb = before_kb == '' || after_kb == '' ? '' : after_kb - before_kb
  resident_rows << [mode, feature, client, round_number, before_kb, after_kb, change_kb]
end

write_tsv.call(File.join(root, 'gc.tsv'),
               %w[mode feature client round gc_snapshot_updated collections_delta full_collections_delta
                  gc_seconds_delta gc_time_percent_of_window latest_live_object_mb latest_live_string_mb],
               gc_rows)
if memory
  write_tsv.call(File.join(root, 'resident.tsv'),
                 %w[mode feature client round resident_before_kb resident_after_kb resident_delta_kb], resident_rows)
end

allocations = lambda do |path|
  counts = Hash.new(0)
  sizes = Hash.new(0)
  next [counts, sizes] unless File.file?(path)

  File.foreach(path) do |line|
    next unless line.start_with?('alloc;', '# bytes ')

    prefix = line.start_with?('alloc;') ? 6 : 8
    key, value = line[prefix..].chomp.rpartition(' ').values_at(0, 2)
    key = key.gsub(/scan_0x[0-9a-fA-F]+/, 'scan_(unmapped)').gsub(/0x[0-9a-fA-F]+/, '0xADDR').split.join(' ')
    (prefix == 6 ? counts : sizes)[key] += Integer(value)
  end
  [counts, sizes]
end

if memory
  alloc_rows = []
  rows.each do |row|
    mode, feature, client, round_number = row.first(4)
    label = "#{mode}-#{feature}-#{client}-r#{round_number}"
    before_count, before_size = allocations.call(File.join(root, "#{label}.alloc.before.folded"))
    after_count, after_size = allocations.call(File.join(root, "#{label}.alloc.after.folded"))
    keys = before_count.keys.to_set | after_count.keys.to_set | before_size.keys.to_set | after_size.keys.to_set
    deltas = keys.map { |key| [key, after_count[key] - before_count[key], after_size[key] - before_size[key]] }
    deltas.reject! { |item| item[1].zero? && item[2].zero? }
    total_count = deltas.sum { |item| item[1] }
    total_bytes = deltas.sum { |item| item[2] }
    deltas << ['TOTAL', total_count, total_bytes, total_bytes.fdiv(row[8]).round(4)]
    deltas.sort_by! { |item| [item[0] == 'TOTAL' ? 1 : 0, -item[2], -item[1]] }
    alloc_rows.concat(deltas.map { |item| [mode, feature, client, round_number, *item] })
  end
  write_tsv.call(File.join(root, 'allocations.tsv'),
                 %w[mode feature client round site_type allocation_count_delta allocated_bytes_delta
                    bytes_per_request], alloc_rows)
end
