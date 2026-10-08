require "kiln"

heads = {
  "wrk" => "GET /svc15/items/42?x=1 HTTP/1.1\r\nHost: example.com\r\nUser-Agent: bench\r\nAccept: */*\r\nConnection: keep-alive".b,
  "browser" => "GET /products/42?ref=home HTTP/1.1\r\nHost: shop.example.com\r\nConnection: keep-alive\r\nsec-ch-ua: \"Chromium\";v=\"128\", \"Not;A=Brand\";v=\"24\"\r\nsec-ch-ua-mobile: ?0\r\nsec-ch-ua-platform: \"macOS\"\r\nUpgrade-Insecure-Requests: 1\r\nUser-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36\r\nAccept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8\r\nSec-Fetch-Site: same-origin\r\nSec-Fetch-Mode: navigate\r\nSec-Fetch-User: ?1\r\nSec-Fetch-Dest: document\r\nReferer: https://shop.example.com/\r\nAccept-Encoding: gzip, deflate, br, zstd\r\nAccept-Language: ru-RU,ru;q=0.9,en-US;q=0.8,en;q=0.7\r\nCookie: session=abc123def456; theme=dark; cart=9f8e7d6c".b
}
n = (ARGV[0] || "300000").to_i
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
