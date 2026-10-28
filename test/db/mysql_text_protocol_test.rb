require 'kiln/db'
require 'test/db/support'

Thread.current

class TextItem < Kiln::DB::Model
end

def need(label, cond)
  return if cond

  print "FAILED #{label}\n"
  raise label
end

def line(db, label, value)
  print "#{db} #{label} #{value}\n"
end

def warning_text(rows)
  parts = []
  i = 0
  while i < rows.length
    row = rows[i]
    need('warning code type', row[1].is_a?(Integer))
    parts << "#{row[0]}:#{row[1]}"
    i += 1
  end
  parts.join(',')
end

def duplicate_rows(conn)
  conn.exec("INSERT IGNORE INTO kiln_text_item (id, name) VALUES (1, 'a'), (1, 'b'), (2, 'c'), (2, 'd')", [])
  conn.warning_count
end

def check_show(db, conn)
  count = duplicate_rows(conn)
  first = conn.exec('SHOW WARNINGS', [])
  again = conn.exec("  /* kiln */ show\n  warnings", [])
  counted = conn.exec('SHOW COUNT(*) WARNINGS', [])
  need("#{db} warnings repeat", warning_text(first) == warning_text(again))
  line(db, 'show warnings', "#{count} #{first.length} #{warning_text(first)}")
  line(db, 'show count', counted[0][0].to_s)
  conn.exec('DELETE FROM kiln_text_item', [])
end

def check_errors(db, conn)
  duplicate_rows(conn)
  errors = conn.exec('SHOW ERRORS', [])
  conn.exec('GET DIAGNOSTICS @kiln_text_n = NUMBER', [])
  number = conn.exec('SELECT @kiln_text_n', [])
  line(db, 'show errors', errors.length.to_s)
  line(db, 'get diagnostics', number[0][0].to_s)
  conn.exec('DELETE FROM kiln_text_item', [])
end

def check_stream(db, conn)
  duplicate_rows(conn)
  seen = []
  conn.each_row('SHOW WARNINGS', []) { |row| seen << row }
  line(db, 'stream warnings', warning_text(seen))
  conn.exec('DELETE FROM kiln_text_item', [])
end

def check_import(db, conn)
  conn.exec("INSERT INTO kiln_text_item (id, name) VALUES (1, 'kept')", [])
  result = TextItem.import([{ 'id' => 1, 'name' => 'dup' }, { 'id' => 3, 'name' => 'new' }],
                           { on_duplicate_key_ignore: true })
  names = TextItem.all.order(TextItem.col('id').asc).pluck(TextItem.col('name'))
  line(db, 'import ignore', "#{result.state} #{names.join(',')}")
  raised = 'none'
  begin
    TextItem.import([{ 'id' => 4, 'name' => 'x' * 40 }], { on_duplicate_key_ignore: true })
  rescue Kiln::DB::Error => e
    raised = e.message
  end
  line(db, 'import other warning', raised)
  need("#{db} usable after warning", !conn.broken?)
end

def check_fallback(db, conn)
  rows = conn.exec('CHECK TABLE kiln_text_item', [])
  line(db, 'check table', "#{rows.length} #{rows[0][2]} #{rows[0][3]}")
  selected = conn.exec('SELECT 7', [])
  unlocked = conn.exec('UNLOCK TABLES', [])
  line(db, 'no stale rows', "#{selected[0][0]} #{unlocked.length}")
  begin
    conn.exec('SHOW WARNINGS LIMIT ?', [1])
    line(db, 'diagnostic binds', 'accepted')
  rescue Kiln::DB::Unsupported
    line(db, 'diagnostic binds', 'unsupported')
  end
  need("#{db} usable after fallback", !conn.broken?)
end

def run_db(db, text, host_key)
  conn = Kiln::DB::Conn.open(Kiln::DB::Native::KIND_MY, env_line(text, "#{host_key}_HOST"),
                             env_line(text, "#{host_key}_PORT").to_i, env_line(text, 'KILN_DB_MY_USER'),
                             env_line(text, 'KILN_DB_MY_PASSWORD'), env_line(text, 'KILN_DB_MY_DB'),
                             "#{env_line(text, 'KILN_DB_CONFIG_DIR')}/ca.crt", env_line(text, 'KILN_DB_TLS_NAME'))
  Kiln::DB::Scope.use(conn)
  conn.exec('DROP TABLE IF EXISTS kiln_text_item', [])
  conn.exec('CREATE TABLE kiln_text_item (id INT NOT NULL, name VARCHAR(20) NOT NULL, PRIMARY KEY (id)) ENGINE=InnoDB',
            [])
  TextItem.define_table(:mysql, 'kiln_text_item', %w[id name], ['id'], 't')
  check_show(db, conn)
  check_errors(db, conn)
  check_stream(db, conn)
  check_import(db, conn)
  check_fallback(db, conn)
  conn.exec('DROP TABLE IF EXISTS kiln_text_item', [])
  Kiln::DB::Scope.use(nil)
  conn.close
end

text = File.read('build/db-runtime/session.env')
run_db('mysql84', text, 'DB_MY')
run_db('mariadb114', text, 'DB_MARIA')
print "ok mysql text protocol\n"
