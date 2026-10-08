require "kiln"
require "socket"
require "stringio"

def raw(port, data, wait: 1.5)
  s = TCPSocket.new("127.0.0.1", port)
  s.write(data)
  out = (+"").b
  limit = Kiln.now + wait
  loop do
    left = limit - Kiln.now
    break if left <= 0
    r, = IO.select([s], nil, nil, left)
    break unless r
    chunk = begin
              s.readpartial(65_536)
            rescue EOFError, SystemCallError
              nil
            end
    break unless chunk
    out << chunk
  end
  s.close
  out
end

def codes(out) = out.split("\r\n".b).select { |l| l.start_with?("HTTP/1.".b) }.map { |l| l.split(" ".b)[1].to_s }
def body(out) = out.split("\r\n\r\n".b, 2)[1].to_s
def hdr(out, name) = out.split("\r\n".b).select { |l| l.downcase.start_with?("#{name}:".b) }
def get(port, path) = raw(port, "GET #{path} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".b)
def check(label, ok)
  raise "FAIL #{label}" unless ok
  puts "ok   #{label}"
end

class Conn
  def ping = "pong"
end

class H
  def initialize(&b) = @b = b
  def call(ctx) = @b.call(ctx)
end

HITS = Queue.new
MADE = Queue.new
POOL = Kiln::Pool.new(1) { MADE << 1; Conn.new }
CPU = Kiln::CpuPool.new(1)
WATCH = Queue.new
HUGE_BODY = ("z" * (64 * 1024 * 1024)).freeze
LOG = Kiln::Log.new(StringIO.new)

r = Kiln::Router.new
r.get  "/health",  H.new { |c| c.res.text("ok\n") }
r.get  "/host",    H.new { |c| c.res.text(c.req.header("host").to_s) }
r.get  "/empty",   H.new { |c| c.res.text("must not leak", status: 204) }
r.post "/echo",    H.new { |c| c.res.text("len=#{c.req.body.to_s.bytesize}:#{c.req.body}") }
r.get  "/admin",   H.new { |c| HITS << 1; c.res.text("admin\n") }
r.get  "/p/:name", H.new { |c| c.res.text("name=#{c.req.params['name']}") }
r.get  "/cookies", H.new { |c| c.res.headers.add("Set-Cookie", "a=1"); c.res.headers.add("Set-Cookie", "b=2"); c.res.text("c") }
r.get  "/large",   H.new { |c| c.res.text("y" * 1_000_000) }
r.get  "/badstatus", H.new { |c| c.res.status = 100; c.res.body = "secret-body" }
r.get  "/watch",   H.new { |c|
    limit = Kiln.now + 0.2
    gone = false
    until gone || Kiln.now > limit
      gone = c.client_gone?
      Kernel.sleep 0.01
    end
    WATCH << (gone ? :gone : :timeout)
    c.res.text("watched")
  }
r.get  "/abandoned", H.new { |c| raise Kiln::ClientGone, "client left" }
r.get  "/alive",   H.new { |c| c.res.text(c.client_gone? ? "gone" : "alive") }
r.get  "/evil",    H.new { |c| c.res.headers["X-Evil"] = "a\r\nInjected: yes"; c.res.text("e") }
r.get  "/sleep",   H.new { |c| c.sleep(5); c.res.text("late") }
r.get  "/swallow", H.new { |c|
    begin
      c.sleep(5)
    rescue StandardError
      nil
    end
    Kernel.sleep 5
    c.res.text("swallowed") }
r.get  "/pool",    H.new { |c| POOL.with(timeout: 5) { |x| x.ping }; c.res.text("pool") }
r.get  "/stuck",   H.new { |c| POOL.with(timeout: 5) { |x| Kernel.sleep 5 }; c.res.text("stuck") }
r.get  "/cpu",     H.new { |c| c.res.text("cpu=#{CPU.run { 7 }}") }
r.get  "/big",     H.new { |c| c.res.text("x" * 4_000_000) }
r.get  "/huge",    H.new { |c| c.res.text(HUGE_BODY) }

srv = Kiln::Server.new(Kiln::Rescue.new(r, LOG), nil, log: LOG, port: 0, host: "127.0.0.1",
                       request_timeout: 0.3, kill_grace: 0.2, write_timeout: 0.5, max_conns: 50)
srv.start
pt = srv.port

puts "-- protocol"
check "GET /health 200", codes(get(pt, "/health")) == ["200"]
o = raw(pt, "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nContent-Length: 5\r\n\r\n0\r\n\r\nGET /admin HTTP/1.1\r\nHost: x\r\n\r\n".b)
check "TE+CL -> 400, hidden request is not executed", codes(o) == ["400"] && HITS.empty?
o = raw(pt, "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n5\r\nhello\r\n0\r\n\r\n".b)
check "chunked body is decoded", body(o) == "len=5:hello"
o = raw(pt, "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n0\r\nX-Trace: ok\r\n\r\n".b)
check "valid trailer is accepted", codes(o) == ["200"] && body(o) == "len=0:"
check "space before chunk size -> 400", codes(raw(pt, "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n 5\r\nhello\r\n0\r\n\r\n".b)) == ["400"]
check "invalid trailer -> 400", codes(raw(pt, "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n0\r\nBad-Trailer\r\n\r\n".b)) == ["400"]
check "Content-Length in trailer -> 400", codes(raw(pt, "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n0\r\nContent-Length: 3\r\n\r\n".b)) == ["400"]
trailers = ("X-Trace: " + "a" * 2000 + "\r\n") * 9
check "total trailer size is limited", codes(raw(pt, "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n0\r\n#{trailers}\r\n".b)) == ["431"]
check "tab in request line -> 400", codes(raw(pt, "GET\t/health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".b)) == ["400"]
check "duplicate Content-Length -> 400", codes(raw(pt, "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 1\r\nContent-Length: 5\r\n\r\nHELLO".b)) == ["400"]
check "Content-Length 5abc -> 400", codes(raw(pt, "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 5abc\r\n\r\nhello".b)) == ["400"]
o = raw(pt, "POST /echo HTTP/1.0\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n0\r\n\r\n".b)
check "TE in HTTP/1.0 -> 400 and response stays HTTP/1.0", codes(o) == ["400"] && o.start_with?("HTTP/1.0 400 ")
check "HTTP/1.1 without Host -> 400", codes(raw(pt, "GET /health HTTP/1.1\r\nConnection: close\r\n\r\n".b)) == ["400"]
check "empty Host in HTTP/1.1 -> 400", codes(raw(pt, "GET /health HTTP/1.1\r\nHost: \r\nConnection: close\r\n\r\n".b)) == ["400"]
check "absolute-form: Host ignored per RFC 9112", codes(raw(pt, "GET http://example.com/health HTTP/1.1\r\nHost: \r\nConnection: close\r\n\r\n".b)) == ["200"]
slow = TCPSocket.new("127.0.0.1", pt)
["GET /health HTTP/1.1\r\nHost: x\r\nConnection: close", "\r", "\n\r", "\n"].each { |part| slow.write(part); Kernel.sleep 0.03 }
IO.select([slow], nil, nil, 2)
slow_resp = slow.readpartial(4096) rescue ""
slow.close
check "header terminator split across three reads is found", slow_resp.start_with?("HTTP/1.1 200")
batch = (+"").b
15.times { batch << "GET /health HTTP/1.1\r\nHost: x\r\n\r\n".b }
batch << "GET /health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".b
check "16 pipelined requests in one packet -> 16 responses", raw(pt, batch).scan("HTTP/1.1 200 ".b).size == 16
o = raw(pt, "GET /health HTTP/1.1\r\nHost: x\r\n\r\nGET /health HTTP/9.9\r\n\r\n".b)
check "pipelined good + malformed: 200 is sent before 400", o.index("HTTP/1.1 200 ".b) == 0 && o.include?(" 400 ".b)
cont = TCPSocket.new("127.0.0.1", pt)
cont.write("GET /health HTTP/1.1\r\nHost: x\r\n\r\nPOST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\nExpect: 100-continue\r\nConnection: close\r\n\r\n".b)
seen = (+"").b
limit = Kiln.now + 2
until seen.include?("100 Continue".b) || Kiln.now > limit
  IO.select([cont], nil, nil, 0.2)
  seen << (cont.read_nonblock(4096, exception: false) rescue "").to_s.b
end
first_ok = seen.index("HTTP/1.1 200 ".b)
cont_at = seen.index("HTTP/1.1 100 Continue".b)
cont.write("hi")
check "pipelined response is sent before 100 Continue", first_ok == 0 && cont_at && cont_at > first_ok
cont.close
o = raw(pt, "GET /health HTTP/1.1\r\nHost: x\r\n\r\nGET /swallow HTTP/1.1\r\nHost: x\r\n\r\n".b, wait: 3)
check "pipelined good + stuck handler: 200 then 504 from reaper", o.index("HTTP/1.1 200 ".b) == 0 && o.include?("HTTP/1.1 504 ".b)
watcher = TCPSocket.new("127.0.0.1", pt)
watcher.write("GET /watch HTTP/1.1\r\nHost: x\r\n\r\n")
Kernel.sleep 0.03
watcher.close
t_watch = Kiln.now
seen_gone = WATCH.pop(timeout: 3)
check "handler sees client disconnect via client_gone?", seen_gone == :gone && Kiln.now - t_watch < 1.0
o = raw(pt, "GET /alive HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".b)
check "client_gone? is false while the client waits", body(o) == "alive"
half = TCPSocket.new("127.0.0.1", pt)
half.write("GET /watch HTTP/1.1\r\nHost: x\r\n\r\n")
Kernel.sleep 0.03
half.write("GET /unread HTTP/1.1\r\n")
half.shutdown(Socket::SHUT_WR)
seen_half = WATCH.pop(timeout: 3)
expected_half = Kiln::HttpNative.kiln_peer_closed_uses_rdhup == 1 ? :gone : :timeout
check "client_gone? follows platform semantics with unread bytes pending", seen_half == expected_half
half.close
o = raw(pt, "GET /abandoned HTTP/1.1\r\nHost: x\r\n\r\n".b, wait: 2)
check "ClientGone closes the connection without a 500 response", o.empty?
check "GET * -> 400", codes(raw(pt, "GET * HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".b)) == ["400"]
o = raw(pt, "GET /badstatus HTTP/1.1\r\nHost: x\r\n\r\nGET /health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".b)
first_end = o.index("internal error\n".b)
check "invalid status: 500 with full body; next response remains aligned", o.start_with?("HTTP/1.1 500 ".b) && first_end && o.byteslice(first_end + 15, 13) == "HTTP/1.1 200 ".b && !o.include?("secret-body".b)
o = raw(pt, "OPTIONS * HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".b)
allow = hdr(o, "allow")[0].to_s
check "OPTIONS * -> 204 with method list", codes(o) == ["204"] && allow.include?("GET".b) && allow.include?("OPTIONS".b)
check "authority-form without CONNECT -> 400", codes(raw(pt, "GET example.com:443 HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".b)) == ["400"]
check "CONNECT -> 501", codes(raw(pt, "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n".b)) == ["501"]
tiny = (+"POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n").b
ext = ";" + ("e" * 3000)
40.times { tiny << "1#{ext}\r\nx\r\n".b }
tiny << "0\r\n\r\n".b
check "chunked with oversized extensions -> 400 (overhead limit)", codes(raw(pt, tiny)) == ["400"]
o = get(pt, "/cookies")
check "multiple Set-Cookie headers reach the client", hdr(o, "set-cookie") == ["Set-Cookie: a=1".b, "Set-Cookie: b=2".b]
o = raw(pt, "GET /large HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".b, wait: 3)
check "large response is received in full", codes(o) == ["200"] && body(o).bytesize == 1_000_000 && hdr(o, "content-length") == ["Content-Length: 1000000".b]
o = raw(pt, "HEAD /large HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".b)
check "HEAD for large response: length present, no body", hdr(o, "content-length") == ["Content-Length: 1000000".b] && body(o).empty?
check "TE gzip (chunked is not last) -> 400", codes(raw(pt, "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip\r\n\r\n".b)) == ["400"]
check "TE gzip, chunked (unknown coding) -> 501", codes(raw(pt, "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip, chunked\r\n\r\n".b)) == ["501"]
check "duplicate chunked coding -> 400", codes(raw(pt, "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked, chunked\r\n\r\n".b)) == ["400"]
check "unknown Expect -> 417", codes(raw(pt, "POST /echo HTTP/1.1\r\nHost: x\r\nExpect: magic\r\nContent-Length: 1\r\n\r\nx".b)) == ["417"]
many = (+"GET /health HTTP/1.1\r\nHost: x\r\n").b
101.times { |i| many << "X-H#{i}: v\r\n".b }
many << "\r\n".b
check "more than 100 headers -> 431", codes(raw(pt, many)) == ["431"]
o = get(pt, "/health")
check "response includes Date", hdr(o, "date").size == 1 && hdr(o, "date")[0].end_with?(" GMT".b)
s413 = TCPSocket.new("127.0.0.1", pt)
s413.write("POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 5000000\r\n\r\n")
sender = Thread.new do
  chunk = "x" * 65_536
  begin
    40.times { s413.write(chunk) }
  rescue IOError, SystemCallError
    nil
  end
end
IO.select([s413], nil, nil, 2)
first413 = begin
             s413.readpartial(4096)
           rescue EOFError, SystemCallError
             ""
           end
sender.join
s413.close
check "413 reaches a client still sending its body", first413.start_with?("HTTP/1.1 413")
check "Host with space -> 400", codes(raw(pt, "GET /health HTTP/1.1\r\nHost: x y\r\nConnection: close\r\n\r\n".b)) == ["400"]
check "IPv6 Host with port is accepted", codes(raw(pt, "GET /health HTTP/1.1\r\nHost: [::1]:80\r\nConnection: close\r\n\r\n".b)) == ["200"]
check "Host with invalid percent escape -> 400", codes(raw(pt, "GET /health HTTP/1.1\r\nHost: x%GG\r\nConnection: close\r\n\r\n".b)) == ["400"]
o = raw(pt, "GET http://target.example/host HTTP/1.1\r\nHost: other.example\r\nConnection: close\r\n\r\n".b)
check "absolute-form is routed and replaces Host", codes(o) == ["200"] && body(o) == "target.example"
check "userinfo in absolute-form -> 400", codes(raw(pt, "GET http://user@host/health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".b)) == ["400"]
check "absolute-form scheme is case-insensitive", codes(raw(pt, "GET HTTP://target.example/health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".b)) == ["200"]
check "method is case-sensitive -> 405", codes(raw(pt, "get /health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".b)) == ["405"]
check "body > max_body -> 413", codes(raw(pt, "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 5000000\r\n\r\n".b)) == ["413"]
o = raw(pt, "HEAD /health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".b)
check "HEAD: same Content-Length as GET, no body", hdr(o, "content-length") == ["Content-Length: 3".b] && body(o).empty?
o = raw(pt, "GET /empty HTTP/1.1\r\nHost: x\r\n\r\nGET /health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".b)
check "204 does not corrupt next keep-alive response", codes(o) == ["204", "200"] && !o.include?("must not leak")
s = TCPSocket.new("127.0.0.1", pt)
s.write("POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\nExpect: 100-continue\r\nConnection: close\r\n\r\n")
IO.select([s], nil, nil, 1)
first = s.readpartial(4096)
s.write("hi"); IO.select([s], nil, nil, 1); rest = s.readpartial(4096) rescue ""
s.close
check "100 Continue without Content-Length, then 200", first.start_with?("HTTP/1.1 100 Continue\r\n\r\n") && rest.to_s.include?("len=2:hi")
check "//admin is distinct from /admin", codes(get(pt, "//admin")) == ["404"] && HITS.empty?
check "%20 is decoded in route parameter", body(get(pt, "/p/a%20b")) == "name=a b"
check "%00 in path -> 400", codes(get(pt, "/p/a%00b")) == ["400"]
o = raw(pt, "DELETE /health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".b)
check "unsupported method -> 405 with Allow", codes(o) == ["405"] && hdr(o, "allow") == ["Allow: GET, HEAD".b]
o = get(pt, "/evil")
check "header containing CR/LF is discarded", codes(o) == ["200"] && hdr(o, "injected").empty? && hdr(o, "x-evil").empty?

puts "-- strict chunked boundaries"
prefix = "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
["3;", "3;=x", '3;foo="', "3;foo=bad space", "3;foo="].each do |line|
  check "invalid extension #{line.inspect} -> 400", codes(raw(pt, "#{prefix}#{line}\r\nabc\r\n0\r\n\r\n".b)) == ["400"]
end
['3;foo="a\\"b"', "3 ; foo = bar", "0000000000000003"].each do |line|
  check "valid size/extension #{line.inspect}", body(raw(pt, "#{prefix}#{line}\r\nabc\r\n0\r\n\r\n".b)) == "len=3:abc"
end
check "very large hex size -> 413 without overflow", codes(raw(pt, "#{prefix}FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF\r\n".b)) == ["413"]
check "absolute-form without Host -> 400", codes(raw(pt, "GET http://example.com/health HTTP/1.1\r\nConnection: close\r\n\r\n".b)) == ["400"]
check "origin-form without Host -> 400", codes(raw(pt, "GET /health HTTP/1.1\r\nConnection: close\r\n\r\n".b)) == ["400"]

puts "-- deadlines"
t = Kiln.now; o = get(pt, "/sleep")
check "ctx.sleep hits deadline -> fast 504", codes(o) == ["504"] && Kiln.now - t < 0.45
t = Kiln.now; o = get(pt, "/swallow")
check "handler that ignores deadline is killed by reaper -> 504", codes(o) == ["504"] && Kiln.now - t < 1.0
holder = Thread.new { POOL.with(timeout: 5) { |x| Kernel.sleep 0.8 } }
Kernel.sleep 0.05
t = Kiln.now; o = get(pt, "/pool")
check "pool wait is bounded by deadline -> 504", codes(o) == ["504"] && Kiln.now - t < 0.45
holder.join
made_before = MADE.size
o = get(pt, "/stuck")
Kernel.sleep 0.1
check "resource held during with is closed after kill; slot restored", codes(o) == ["504"] && POOL.available == 1
check "next checkout lazily creates a new resource", codes(get(pt, "/pool")) == ["200"] && MADE.size == made_before + 1
busy = Thread.new { CPU.run(timeout: 5) { Kernel.sleep 0.6; 1 } }
Kernel.sleep 0.05
o = get(pt, "/cpu")
busy.join
Kernel.sleep 0.05
check "CpuPool: 504; task after deadline was not started", codes(o) == ["504"] && CPU.skipped == 1
check "CpuPool remains alive", codes(get(pt, "/cpu")) == ["200"]

swallowers = 5.times.map { Thread.new { codes(get(pt, "/swallow")) } }
results = swallowers.map(&:value)
check "five stuck requests at once -> all receive 504", results == [["504"]] * 5
puts "-- write timeout"
class GatedTimeoutServer < Kiln::Server
  attr_accessor :write_entered, :continue_write

  def write_all(sock, data, deadline)
    if data.bytesize == HUGE_BODY.bytesize
      @write_entered << true
      @continue_write.pop
    end
    super
  end
end

slow_srv = GatedTimeoutServer.new(->(ctx) { ctx.res.text(HUGE_BODY) }, nil,
                                  log: Kiln::Log.new(StringIO.new), port: 0, host: "127.0.0.1",
                                  write_timeout: 0.2, max_conns: 1)
write_entered = Queue.new
continue_write = Queue.new
slow_srv.write_entered = write_entered
slow_srv.continue_write = continue_write
slow_srv.start
s = TCPSocket.new("127.0.0.1", slow_srv.port)
s.write("GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
check "write reaches response body", write_entered.pop(timeout: 2) == true
Kernel.sleep 0.25
continue_write << true
slow_limit = Kiln.now + 2.0
Kernel.sleep 0.01 while slow_srv.connections > 0 && Kiln.now < slow_limit
check "expired write deadline closes the connection", slow_srv.connections == 0
s.close
slow_srv.shutdown(grace: 0)

puts "-- in-flight request accounting"
ka = TCPSocket.new("127.0.0.1", pt)
200.times { ka.write("GET /health HTTP/1.1\r\nHost: x\r\n\r\n") }
got = (+"").b
limit = Kiln.now + 3
while got.scan("HTTP/1.1 200".b).size < 200 && Kiln.now < limit
  r, = IO.select([ka], nil, nil, limit - Kiln.now)
  break unless r
  got << ka.readpartial(65_536)
end
ka.close
Kernel.sleep 0.1
check "200 requests served on one connection", got.scan("HTTP/1.1 200".b).size == 200
check "in-flight request set is empty (no leak)", srv.handling == 0
puts "-- lifecycle: slot held until thread exits"
class Lingering
  def call(ctx)
    begin
      Kernel.sleep 5
    ensure
      Kernel.sleep 0.4
    end
    ctx.res.text("never")
  end
end
lr = Kiln::Router.new
lr.get("/linger", Lingering.new)
lsrv = Kiln::Server.new(Kiln::Rescue.new(lr, LOG), nil, log: LOG, port: 0, host: "127.0.0.1",
                        request_timeout: 0.2, kill_grace: 0.1, max_conns: 2)
lsrv.start
lp = lsrv.port
lt = Thread.new { raw(lp, "GET /linger HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".b, wait: 2) }
Kernel.sleep 0.5
check "slot stays occupied after kill while thread is alive", lsrv.killed == 1 && lsrv.free_slots == 1
check "client received 504 from reaper", codes(lt.value) == ["504"]
Kernel.sleep 0.5
check "slot restored after thread exits", lsrv.free_slots == 2 && lsrv.connections == 0
lt2 = Thread.new { raw(lp, "GET /linger HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".b, wait: 2) }
Kernel.sleep 0.4
reaped = lsrv.killed == 2
lsrv.shutdown(grace: 0.1)
lt2.join
Kernel.sleep 0.6
check "shutdown during cleanup releases slot and connection", reaped && lsrv.free_slots == 2 && lsrv.connections == 0

idle_ka = TCPSocket.new("127.0.0.1", pt)
idle_ka.write("GET /health HTTP/1.1\r\nHost: x\r\n\r\n")
IO.select([idle_ka], nil, nil, 2)
idle_ka.readpartial(4096)
Kernel.sleep 0.1
killed_before = srv.killed
puts "-- shutdown"
check "in-flight is 0; reaper killed exactly eight threads", srv.in_flight == 0 && srv.killed == 8
check "shutdown returned 0", srv.shutdown(grace: 1.0) == 0
Kernel.sleep 0.1
check "idle keep-alive connection closed without kill", srv.killed == killed_before && srv.connections == 0
idle_ka.close
check "repeated shutdown is safe", srv.shutdown(grace: 1.0) == 0
LOG.close
