require 'kiln'

heads = {
  'wrk' => "GET /svc15/items/42?x=1 HTTP/1.1\r\nHost: example.com\r\n" \
           "User-Agent: bench\r\nAccept: */*\r\nConnection: keep-alive".b,
  'browser' => "GET /products/42?ref=home HTTP/1.1\r\n" \
               "Host: shop.example.com\r\n" \
               "Connection: keep-alive\r\n" \
               "sec-ch-ua: \"Chromium\";v=\"128\", \"Not;A=Brand\";v=\"24\"\r\n" \
               "sec-ch-ua-mobile: ?0\r\n" \
               "sec-ch-ua-platform: \"macOS\"\r\n" \
               "Upgrade-Insecure-Requests: 1\r\n" \
               'User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) ' \
               'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safa' \
               "ri/537.36\r\n" \
               "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8\r\n" \
               "Sec-Fetch-Site: same-origin\r\n" \
               "Sec-Fetch-Mode: navigate\r\n" \
               "Sec-Fetch-User: ?1\r\n" \
               "Sec-Fetch-Dest: document\r\n" \
               "Referer: https://shop.example.com/\r\n" \
               "Accept-Encoding: gzip, deflate, br, zstd\r\n" \
               "Accept-Language: ru-RU,ru;q=0.9,en-US;q=0.8,en;q=0.7\r\n" \
               'Cookie: session=abc123def456; theme=dark; cart=9f8e7d6c'.b
}
n = (ARGV[0] || '300000').to_i
out = Kiln::HttpNative.scratch
heads.each do |name, head|
  t = Kiln.now
  n.times { Kiln::HttpSyntax.parse_head(head) }
  ruby = Kiln.now - t
  t = Kiln.now
  n.times { Kiln::HttpNative.parse_head(head, out) }
  native = Kiln.now - t
  puts "#{name} parses=#{n} ruby_us=#{(ruby / n * 1e6).round(2)} native_us=#{(native / n * 1e6).round(2)}"
end
