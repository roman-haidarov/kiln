require 'json'

own_root = File.realpath(ARGV.fetch(0))
own_db = File.join(own_root, 'db/')
own = 0
external = 0

def finding_paths(result)
  places = []
  collect = lambda do |location|
    uri = location.dig('physicalLocation', 'artifactLocation', 'uri')
    line = location.dig('physicalLocation', 'region', 'startLine')
    places << [uri, line] if uri
  end
  (result['locations'] || []).each(&collect)
  (result['codeFlows'] || []).each do |flow|
    (flow['threadFlows'] || []).each do |thread|
      (thread['locations'] || []).each { |step| collect.call(step['location'] || {}) }
    end
  end
  places
end

def local_path(uri)
  path = uri.sub(%r{\Afile://}, '').gsub(/%\h\h/) { |code| code[1, 2].hex.chr }
  File.exist?(path) ? File.realpath(path) : path
end

ARGV.drop(1).each do |report|
  JSON.parse(File.read(report)).fetch('runs', []).each do |run|
    (run['results'] || []).each do |result|
      places = finding_paths(result).map { |uri, line| [local_path(uri), line] }
      where = places.first || ['?', nil]
      text = "#{where[0]}:#{where[1]}: #{result['ruleId']}: #{result.dig('message', 'text')}"
      if places.any? { |path, _| File.dirname(path) == own_root || path.start_with?(own_db) }
        own += 1
        puts "analyzer: #{text}"
      else
        external += 1
        puts "analyzer (external, not gating): #{text}"
      end
    end
  end
end

puts "analyzer: #{own} finding(s) on a path through Kiln sources, #{external} only in external or vendored code"
exit(own.zero? ? 0 : 1)
