require 'kiln/db'

ROWS = 200
COLS = 5
KINDS = [1, 4, 4, 4, 5]
SQL = "WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM s WHERE n < 200) SELECT CASE WHEN n % 17 = 0 THEN NULL ELSE n END, CASE WHEN n % 19 = 0 THEN NULL WHEN n % 3 = 0 THEN CONCAT('short-', n) ELSE CONCAT('longer-value-', n, '-', n, '-tail') END, CASE WHEN n % 23 = 0 THEN NULL ELSE CONCAT(n, '.00') END, CASE WHEN n % 29 = 0 THEN NULL ELSE CONCAT(substr(md5(CONCAT(n, '')), 1, 8), '-', substr(md5(CONCAT(n, '')), 9, 4), '-4', substr(md5(CONCAT(n, '')), 13, 3), '-a', substr(md5(CONCAT(n, '')), 17, 3), '-', substr(md5(CONCAT(n, '')), 21, 12)) END, CASE n % 8 WHEN 0 THEN 'alpha' WHEN 1 THEN 'beta' WHEN 2 THEN 'gamma' WHEN 3 THEN 'delta' WHEN 4 THEN 'epsilon' WHEN 5 THEN 'zeta' WHEN 6 THEN 'eta' ELSE 'theta' END FROM s"

def env_line(text, key)
  prefix = "#{key}="
  i = 0
  while i < text.length
    line_end = i
    while line_end < text.length && text[line_end] != "\n"
      line_end += 1
    end
    line = text[i, line_end - i]
    if line.length >= prefix.length && line[0, prefix.length] == prefix
      return line[prefix.length, line.length - prefix.length]
    end

    i = line_end + 1
  end
  nil
end

def need(label, cond)
  return if cond

  print label
  print "\n"
  raise label
end

def later(ms)
  Kiln::DB::Native.now_ms + ms
end

def must(handle, op, ms, label)
  out = Kiln::DB::Native.drive(handle, 1, 1, op, later(ms))
  return if out[0] == Kiln::DB::Native::STEP_DONE

  print label
  print ' '
  print out[0]
  print ' '
  print out[4]
  print ' '
  print Kiln::DB::Native.kiln_db_error_text(handle, 1, 1)
  print "\n"
  raise label
end

def zeros(n)
  out = []
  i = 0
  while i < n
    out << 0
    i += 1
  end
  out
end

def mix(acc, byte)
  ((acc * 33) ^ byte) & 2_147_483_647
end

def mix_slice(acc, text, start, len)
  j = 0
  while j < len
    acc = mix(acc, text[start + j].ord)
    j += 1
  end
  acc
end

def note_form(forms, col, is_null, _text, length)
  return if forms.nil?

  if is_null
    forms[0] += 1
    return
  end
  forms[1] += 1 if col == 1 && length > 12
  forms[2] += 1 if col == 2
  if col == 3
    if length != 36
      print 'uuid-len '
      print length
      print "\n"
      raise 'uuid'
    end
    forms[3] += 1
  end
  forms[4] += 1 if col == 4
end

def mix_copy_cell(acc, col, cell, words, forms)
  acc = mix(acc, col)
  if cell[1] != 0
    note_form(forms, col, true, nil, 0)
    return mix(mix(acc, 0), 7)
  end
  note_form(forms, col, false, cell[0], cell[2])
  if col.zero?
    words[0] = 0
    words[1] = 0
    need('i64', Kiln::DB::Native.i64_parse(cell[0], words) == Kiln::DB::Native::OK)
    return mix(mix(acc, words[1] & 255), 9)
  end
  mix(mix_slice(acc, cell[0], 0, cell[2]), 9)
end

def walk_copy(handle, rows, words, forms)
  sums = zeros(COLS)
  got = 0
  bytes = 0
  guard = 0
  while guard < 500
    meta = Kiln::DB::Native.result_meta(handle, 1, 1)
    if meta[1].positive?
      r = 0
      while r < meta[1]
        c = 0
        while c < COLS
          cell = Kiln::DB::Native.result_bytes(handle, 1, 1, r, c)
          sums[c] = mix_copy_cell(sums[c], c, cell, words, forms)
          bytes += cell[2] if cell[1].zero?
          c += 1
        end
        got += 1
        r += 1
      end
    end
    break if meta[2] == 1

    must(handle, Kiln::DB::Native::OP_DRAIN, 15_000, 'drain')
    guard += 1
  end
  need('rows', got == rows && guard < 500)
  [combine_columns(sums), bytes]
end

def mix_numbers(acc, col, values, nulls, n)
  i = 0
  while i < n
    acc = mix(acc, col)
    acc = if nulls[i].zero?
            mix(mix(acc, values[i] & 255), 9)
          else
            mix(mix(acc, 0), 7)
          end
    i += 1
  end
  acc
end

def mix_text_column(acc, col, text, offs, lens, n)
  i = 0
  while i < n
    acc = mix(acc, col)
    acc = if offs[i].negative?
            mix(mix(acc, 0), 7)
          else
            mix(mix_slice(acc, text, offs[i], lens[i]), 9)
          end
    i += 1
  end
  acc
end

def combine_columns(sums)
  acc = 0
  i = 0
  while i < sums.length
    acc = ((acc * 33) ^ sums[i]) & 2_147_483_647
    i += 1
  end
  acc
end

def fill_block(handle, block, rows)
  dest = 0
  bytes = 0
  guard = 0
  while guard < 500
    meta = Kiln::DB::Native.result_meta(handle, 1, 1)
    if meta[1].positive?
      stats = [0, 0]
      need('import', Kiln::DB::Native.block_import(handle, block, [1, 1], dest, stats) == Kiln::DB::Native::OK)
      dest += stats[0]
      bytes += stats[1]
    end
    break if meta[2] == 1

    must(handle, Kiln::DB::Native::OP_DRAIN, 15_000, 'drain')
    guard += 1
  end
  need('rows', dest == rows && guard < 500)
  bytes
end

def walk_block(handle, rows, values, nulls, offs, lens)
  opened = Kiln::DB::Native.block_open(1, 1, rows, COLS, KINDS)
  need('block', opened[0] == Kiln::DB::Native::OK)
  block = opened[1]
  arena = opened[2]
  bytes = fill_block(handle, block, rows)
  sums = zeros(COLS)
  need('i64', Kiln::DB::Native.copy_i64(block, 1, 1, 0, values) == Kiln::DB::Native::OK)
  need('nulls', Kiln::DB::Native.copy_null_rows(block, 1, 1, 0, nulls) == Kiln::DB::Native::OK)
  sums[0] = mix_numbers(0, 0, values, nulls, rows)
  col = 1
  while col < COLS
    meta = [0, 0]
    text = Kiln::DB::Native.block_text(block, [1, 1], col, [offs, lens, meta])
    need('text', meta[0] >= 0 && meta[1] == rows)
    sums[col] = mix_text_column(0, col, text, offs, lens, rows)
    col += 1
  end
  need('close', Kiln::DB::Native.block_close(block, arena, 1, 1) == Kiln::DB::Native::OK)
  [combine_columns(sums), bytes]
end

def pct_index(n, pct)
  index = (((n * pct) + 99) / 100) - 1
  index = 0 if index.negative?
  index = n - 1 if index >= n
  index
end

def rank(values, index)
  tmp = []
  i = 0
  while i < values.length
    v = values[i]
    tmp << v
    j = tmp.length - 1
    while j.positive? && tmp[j - 1] > v
      tmp[j] = tmp[j - 1]
      j -= 1
    end
    tmp[j] = v
    i += 1
  end
  tmp[index]
end

def emit(db, path, totals, afters, checksum, payload)
  n = totals.length
  print db
  print ' '
  print path
  print ' n '
  print n
  print ' p50 '
  print rank(totals, pct_index(n, 50))
  print ' p99 '
  print rank(totals, pct_index(n, 99))
  print ' after50 '
  print rank(afters, pct_index(n, 50))
  print ' after99 '
  print rank(afters, pct_index(n, 99))
  print ' sum '
  print checksum
  print ' bytes '
  print payload
  print "\n"
end

def time_path(handle, rows, path, iters, expected, payload_expected, words, values, nulls, offs, lens, forms)
  totals = []
  afters = []
  checksum = 0
  payload = 0
  i = 0
  while i < iters + 1
    record = i.zero? ? forms : nil
    t0 = Kiln::DB::Native.now_ms
    must(handle, Kiln::DB::Native::OP_EXEC, 15_000, path)
    t1 = Kiln::DB::Native.now_ms
    if path == 'copy'
      got = walk_copy(handle, rows, words, record)
    elsif path == 'block'
      got = walk_block(handle, rows, values, nulls, offs, lens)
    end
    t2 = Kiln::DB::Native.now_ms
    need(path, t2 >= t0)
    if i.zero?
      checksum = got[0]
      payload = got[1]
      if !expected.nil? && checksum != expected
        print 'sum mismatch '
        print path
        print ' expected '
        print expected
        print ' got '
        print checksum
        print "\n"
        raise 'sum'
      end
      need('bytes', payload_expected.nil? || payload == payload_expected)
    else
      if got[0] != checksum
        print 'sum mismatch '
        print path
        print ' expected '
        print checksum
        print ' got '
        print got[0]
        print "\n"
        raise 'sum'
      end
      need('bytes', got[1] == payload)
      totals << (t2 - t0)
      afters << (t2 - t1)
    end
    i += 1
  end
  [checksum, payload, totals, afters]
end

def prepare(handle, label)
  need(label, Kiln::DB::Native.set_format(handle, 1, 1, 0, 0) == Kiln::DB::Native::OK)
  need(label, Kiln::DB::Native.set_sql(handle, 1, 1, SQL) == Kiln::DB::Native::OK)
  must(handle, Kiln::DB::Native::OP_PREPARE, 15_000, label)
end

def open_db(kind, host, port, user, password, database, ca_path, tls_name, label)
  opened = Kiln::DB::Native.open_conn(kind, 1, 1)
  need(label, opened[0] != 0 && opened[1] == Kiln::DB::Native::OK)
  handle = opened[0]
  endpoint = Kiln::DB::Endpoint.new(host, port, [user, password, database])
  endpoint.secure(Kiln::DB::Native::SSL_VERIFY_FULL, ca_path, tls_name)
  rc = Kiln::DB::Native.connect_params(handle, 1, 1, endpoint)
  need(label, rc == Kiln::DB::Native::OK)
  must(handle, Kiln::DB::Native::OP_CONNECT, 15_000, label)
  handle
end

def show_forms(db, forms)
  print 'forms '
  print db
  print ' null '
  print forms[0]
  print ' long '
  print forms[1]
  print ' decimal '
  print forms[2]
  print ' uuid '
  print forms[3]
  print ' dict '
  print forms[4]
  print "\n"
  need('forms', forms.all?(&:positive?))
end

def run_db(db, kind, host, port, user, password, database, ca_path, tls_name, mode, iters, words, values, nulls, offs,
           lens)
  handle = open_db(kind, host, port, user, password, database, ca_path, tls_name, db)
  prepare(handle, db)
  expected = nil
  payload = nil
  if mode == 'all' || mode == 'copy'
    forms = [0, 0, 0, 0, 0]
    got = time_path(handle, ROWS, 'copy', iters, nil, nil, words, values, nulls, offs, lens, forms)
    show_forms(db, forms)
    expected = got[0]
    payload = got[1]
    emit(db, 'copy', got[2], got[3], got[0], got[1])
  end
  if mode == 'all' || mode == 'block'
    got = time_path(handle, ROWS, 'block', iters, expected, payload, words, values, nulls, offs, lens, nil)
    emit(db, 'block', got[2], got[3], got[0], got[1])
  end
  must(handle, Kiln::DB::Native::OP_CLOSE, 15_000, db)
end

def want_number(raw, fallback)
  return fallback if raw.nil? || raw == ''

  value = raw.to_i
  return fallback if value < 1

  value
end

path = 'build/db-runtime/session.env'
unless File.exist?(path)
  print "blocked gate-b\n"
  exit 0
end

text = File.read(path)
ca_path = "#{env_line(text, 'KILN_DB_CONFIG_DIR')}/ca.crt"
tls_name = env_line(text, 'KILN_DB_TLS_NAME')
pg_user = env_line(text, 'KILN_DB_PG_USER')
pg_password = env_line(text, 'KILN_DB_PG_PASSWORD')
pg_db = env_line(text, 'KILN_DB_PG_DB')
my_user = env_line(text, 'KILN_DB_MY_USER')
my_password = env_line(text, 'KILN_DB_MY_PASSWORD')
my_db = env_line(text, 'KILN_DB_MY_DB')
mode = ENV.fetch('KILN_GATE_B_PATH', nil)
mode = 'all' if mode.nil? || mode == ''
need('path', mode == 'all' || mode == 'copy' || mode == 'block')
iters = want_number(ENV.fetch('KILN_GATE_B_ITERS', nil), 21)
need('configured', Kiln::DB::Native.configure == Kiln::DB::Native::OK)
need('configured', Kiln::DB::Native.load_kind(Kiln::DB::Native::KIND_PG) == Kiln::DB::Native::OK)
need('configured', Kiln::DB::Native.load_kind(Kiln::DB::Native::KIND_MY) == Kiln::DB::Native::OK)
thread_runtime = Thread.current
need('thread-runtime', !thread_runtime.nil?)
print 'rows '
print ROWS
print ' iters '
print iters
print "\n"
words = [0, 0]
values = zeros(ROWS)
nulls = zeros(ROWS)
offs = zeros(ROWS)
lens = zeros(ROWS)
run_db('pg17', Kiln::DB::Native::KIND_PG, env_line(text, 'DB_PG17_HOST'), env_line(text, 'DB_PG17_PORT').to_i, pg_user,
       pg_password, pg_db, ca_path, tls_name, mode, iters, words, values, nulls, offs, lens)
run_db('pg18', Kiln::DB::Native::KIND_PG, env_line(text, 'DB_PG18_HOST'), env_line(text, 'DB_PG18_PORT').to_i, pg_user,
       pg_password, pg_db, ca_path, tls_name, mode, iters, words, values, nulls, offs, lens)
run_db('mysql84', Kiln::DB::Native::KIND_MY, env_line(text, 'DB_MY_HOST'), env_line(text, 'DB_MY_PORT').to_i, my_user,
       my_password, my_db, ca_path, tls_name, mode, iters, words, values, nulls, offs, lens)
run_db('mariadb114', Kiln::DB::Native::KIND_MY, env_line(text, 'DB_MARIA_HOST'), env_line(text, 'DB_MARIA_PORT').to_i,
       my_user, my_password, my_db, ca_path, tls_name, mode, iters, words, values, nulls, offs, lens)
print "ok gate-b\n"
