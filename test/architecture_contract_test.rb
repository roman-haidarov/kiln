require 'kiln'

def check(label, passed)
  raise label unless passed

  puts "ok   #{label}"
end

policy = Kiln::HTTP::RequestPolicy
cases = [
  ['1.1', 'GET', '/', {}, :bad],
  ['1.0', 'GET', '/', {}, nil],
  ['1.1', 'CONNECT', 'example.com:443', { 'host' => 'example.com' }, :not_implemented],
  ['1.1', 'OPTIONS', '*', { 'host' => 'example.com' }, nil],
  ['1.1', 'GET', '*', { 'host' => 'example.com' }, :bad],
  ['1.1', 'GET', 'relative', { 'host' => 'example.com' }, :bad],
  ['1.1', 'GET', '/', { 'host' => 'bad host' }, :bad],
  ['1.1', 'GET', 'http://example.com/x', { 'host' => '' }, nil]
]
cases.each_with_index do |row, index|
  version, verb, target, headers, expected = row
  check("request policy #{index}", policy.head_problem(version, verb, target, headers) == expected)
end
headers = { 'host' => 'proxy.invalid' }
check('absolute form normalizes origin and authority',
      policy.origin('https://example.com?x=1', headers) == '/?x=1' && headers['host'] == 'example.com')
headers = { 'host' => 'original' }
check('invalid absolute authority leaves headers intact',
      policy.origin('http://bad host/x', headers).nil? && headers['host'] == 'original')
check('conflicting framing rejected',
      policy.framing_problem('1.1', { 'transfer-encoding' => 'chunked', 'content-length' => '0' }) == :bad)
check('HTTP 1.0 transfer coding rejected', policy.framing_problem('1.0', { 'transfer-encoding' => 'chunked' }) == :bad)
check('unsupported expectation rejected', policy.framing_problem('1.1', { 'expect' => 'something' }) == :expectation)
check('continue is HTTP 1.1 only',
      policy.continue?({ 'expect' => '100-Continue' }, '1.1') && !policy.continue?({ 'expect' => '100-Continue' }, '1.0'))
check('chunked is accepted', policy.chunked_problem('chunked').nil?)
check('repeated chunked rejected', policy.chunked_problem('chunked, chunked') == :bad)
check('coding after chunked rejected', policy.chunked_problem('chunked, gzip') == :bad)
check('empty coding rejected', policy.chunked_problem(',chunked') == :bad)
check('unsupported coding distinguished', policy.chunked_problem('gzip, chunked') == :unsupported_te)

response = Kiln::HTTP::Response.new
response.text('hello')
request = Kiln::HTTP::Request.new('HEAD', '/', {}, nil)
head, body = Kiln::HTTP::Response.fixed_parts(request, response, true)
check('HEAD preserves representation length', head.include?("Content-Length: 5\r\n") && body.empty?)
request = Kiln::HTTP::Request.new('GET', '/', {}, nil)
[204, 205, 304].each do |status|
  response.text('hidden', status: status)
  head, body = Kiln::HTTP::Response.fixed_parts(request, response, false)
  check("body forbidden for #{status}", body.empty? && head.start_with?("HTTP/1.1 #{status} "))
end
response.text('hidden', status: 101)
head, body = Kiln::HTTP::Response.fixed_parts(request, response, false)
check('invalid fixed status becomes internal error', head.start_with?('HTTP/1.1 500 ') && body == "internal error\n")

config = Kiln::Server::Settings.event(max_conns: 123, max_body: 99, buffer_body: 21,
                                     header_timeout: 1.25, keep_alive_timeout: 0, read_timeout: 2.5,
                                     write_timeout: 3.5, client_disconnect_timeout: 0.25,
                                     tcp_nodelay: false, max_connection_rate: 45, backlog: 67)
check('event configuration preserves native integer layout',
      Kiln::Server::EventConfiguration.pack(config) == [123, 21, 1250, 0, 2500, 3500, 250, 0, 45, 67])
