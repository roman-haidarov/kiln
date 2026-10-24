require 'kiln/db'
require 'test/db/support'

Thread.current

def outcome(label)
  conn = yield
  conn.close
  print "#{label} connected\n"
rescue Kiln::DB::Error => e
  print "#{label} #{e.class.to_s.split('::').last}\n"
end

def tls_state(conn, db)
  if db == 'pg'
    on = conn.exec('SELECT CAST(ssl AS int) FROM pg_stat_ssl WHERE pid = pg_backend_pid()', [])[0][0].to_s == '1'
    return on ? 'on' : 'off'
  end
  conn.exec("SHOW SESSION STATUS LIKE 'Ssl_cipher'", [])[0][1].to_s.empty? ? 'off' : 'on'
end

def plain_outcome(label, db)
  conn = yield
  state = tls_state(conn, db)
  raise 'TLS was not disabled' unless state == 'off'

  print "#{label} tls=#{state}\n"
ensure
  conn&.close
end

text = File.read('build/db-runtime/session.env')
dir = env_line(text, 'KILN_DB_CONFIG_DIR')
ca = "#{dir}/ca.crt"
other = "#{dir}/other-ca.crt"
tls = env_line(text, 'KILN_DB_TLS_NAME')
targets = [
  ['pg', Kiln::DB::Native::KIND_PG, 'DB_PG17', 'KILN_DB_PG'],
  ['mysql', Kiln::DB::Native::KIND_MY, 'DB_MY', 'KILN_DB_MY'],
  ['mariadb', Kiln::DB::Native::KIND_MY, 'DB_MARIA', 'KILN_DB_MY']
]
i = 0
while i < targets.length
  t = targets[i]
  db = t[0]
  kind = t[1]
  host = env_line(text, "#{t[2]}_HOST")
  port = env_line(text, "#{t[2]}_PORT").to_i
  user = env_line(text, "#{t[3]}_USER")
  pass = env_line(text, "#{t[3]}_PASSWORD")
  name = env_line(text, "#{t[3]}_DB")
  outcome("#{db} verify-full") { Kiln::DB::Conn.open(kind, host, port, user, pass, name, ca, tls) }
  outcome("#{db} empty-ca") { Kiln::DB::Conn.open(kind, host, port, user, pass, name, '', tls) }
  outcome("#{db} wrong-name") { Kiln::DB::Conn.open(kind, host, port, user, pass, name, ca, 'wrong.example') }
  outcome("#{db} wrong-ca") { Kiln::DB::Conn.open(kind, host, port, user, pass, name, other, tls) }
  outcome("#{db} system-ca") { Kiln::DB::Conn.open(kind, host, port, user, pass, name, :system, tls) }
  plain_outcome("#{db} plaintext-loopback", db) do
    Kiln::DB::Conn.open(kind, '127.0.0.1', port, user, pass, name, '', '', tls: :disable)
  end
  outcome("#{db} plaintext-remote") { Kiln::DB::Conn.open(kind, '10.255.255.1', port, user, pass, name, '', '', tls: :disable) }
  i += 1
end
