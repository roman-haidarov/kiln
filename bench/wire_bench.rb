require 'kiln'

body = 'x' * 65_536
headers = Kiln::HTTP::Headers.new
headers['Content-Type'] = 'text/plain'
headers['X-Request-Id'] = 'abc'
n = (ARGV[0] || '200000').to_i
t = Kiln::Runtime.now
total = 0
n.times { total += Kiln::HTTP::Response.build_wire(200, headers, body, true).bytesize }
puts "responses=#{n} seconds=#{(Kiln::Runtime.now - t).round(3)} bytes=#{total}"
