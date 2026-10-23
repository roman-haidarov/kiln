require 'kiln/db'
require 'test/db/support'

Thread.current

def now = Kiln::Runtime.now

def open_pg(text, cache)
  ca = "#{env_line(text, 'KILN_DB_CONFIG_DIR')}/ca.crt"
  Kiln::DB::Conn.open(Kiln::DB::Native::KIND_PG, env_line(text, 'DB_PG17_HOST'), env_line(text, 'DB_PG17_PORT').to_i,
                      env_line(text, 'KILN_DB_PG_USER'), env_line(text, 'KILN_DB_PG_PASSWORD'),
                      env_line(text, 'KILN_DB_PG_DB'), ca, env_line(text, 'KILN_DB_TLS_NAME'), statement_cache: cache)
end

def seed(conn)
  conn.exec('DROP TABLE IF EXISTS kiln_skew', [])
  conn.exec('CREATE TABLE kiln_skew (id int PRIMARY KEY, k int NOT NULL)', [])
  conn.exec('INSERT INTO kiln_skew SELECT g, CASE WHEN g % 2 = 0 THEN 1 ELSE g END ' \
            'FROM generate_series(1, 100000) g', [])
  conn.exec('CREATE INDEX kiln_skew_k ON kiln_skew (k)', [])
  conn.exec('ANALYZE kiln_skew', [])
end

def median_us(conn, value)
  spent = []
  i = 0
  while i < 50
    t = now
    conn.exec('SELECT count(*) FROM kiln_skew WHERE k = $1', [value])
    spent << ((now - t) * 1e6)
    i += 1
  end
  spent.sort!
  ((spent[24] + spent[25]) / 2).round(1)
end

def round_line(conn, cache, round)
  common = median_us(conn, 1)
  rare = median_us(conn, 99_999)
  print "skew cache=#{cache} round=#{round} common_us #{common} rare_us #{rare}\n"
end

text = File.read('build/db-runtime/session.env')
setup = open_pg(text, 0)
seed(setup)
[0, 32].each do |cache|
  conn = open_pg(text, cache)
  round = 1
  while round <= 3
    round_line(conn, cache, round)
    round += 1
  end
  conn.close
end
setup.exec('DROP TABLE kiln_skew', [])
setup.close
print "ok plan_skew\n"
