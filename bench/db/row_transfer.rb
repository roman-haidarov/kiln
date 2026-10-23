require 'kiln/db'
require 'test/db/support'

Thread.current

SQL = "SELECT g, 'name-' || g, g * 1.5::float8 FROM generate_series(1, 10000) g".freeze
ROUNDS = 5

def now = Kiln::Runtime.now

def report(label, total, count)
  print label
  print ' '
  print((total / count * 1e9).round)
  print " ns\n"
end

def open_pg(text)
  ca = "#{env_line(text, 'KILN_DB_CONFIG_DIR')}/ca.crt"
  Kiln::DB::Conn.open(Kiln::DB::Native::KIND_PG, env_line(text, 'DB_PG17_HOST'), env_line(text, 'DB_PG17_PORT').to_i,
                      env_line(text, 'KILN_DB_PG_USER'), env_line(text, 'KILN_DB_PG_PASSWORD'),
                      env_line(text, 'KILN_DB_PG_DB'), ca, env_line(text, 'KILN_DB_TLS_NAME'))
end

def hold(conn)
  handle = conn.handle
  Kiln::DB::Native.set_format(handle, 1, 1, 0, 0)
  Kiln::DB::Native.set_sql(handle, 1, 1, SQL)
  Kiln::DB::Native.drive(handle, 1, 1, Kiln::DB::Native::OP_EXEC, Kiln::DB::Native.now_ms + 15_000)
  Kiln::DB::Native.result_meta(handle, 1, 1)
end

def row_calls(handle, count, width, rounds)
  lens = Array.new(width, 0)
  k = 0
  while k < rounds
    r = 0
    while r < count
      Kiln::DB::Native.result_row(handle, 1, 1, r, lens)
      r += 1
    end
    k += 1
  end
end

def rows_round(handle, count, lens, meta)
  r = 0
  while r < count
    Kiln::DB::Native.kiln_db_result_rows(handle, 1, 1, r, 256, 1_048_576, lens, lens.length, meta, 3)
    break unless meta[0].positive?

    r += meta[0]
  end
end

def rows_calls(handle, count, width, rounds)
  lens = Array.new(256 * (width + 1), 0)
  meta = [0, 0, 0]
  k = 0
  while k < rounds
    rows_round(handle, count, lens, meta)
    k += 1
  end
end

def meta_calls(handle, calls)
  i = 0
  while i < calls
    Kiln::DB::Native.result_meta(handle, 1, 1)
    i += 1
  end
end

def token_calls(calls)
  i = 0
  while i < calls
    Kiln::DB::Native.kiln_db_os_thread_token
    i += 1
  end
end

def exec_rounds(conn, rounds)
  k = 0
  while k < rounds
    conn.exec(SQL, [])
    k += 1
  end
end

def codec_rounds(raws, lens_list, types, width, rounds)
  k = 0
  while k < rounds
    r = 0
    while r < raws.length
      Kiln::DB::Codec.row(raws[r], lens_list[r], types, width)
      r += 1
    end
    k += 1
  end
end

text = File.read('build/db-runtime/session.env')
conn = open_pg(text)
other = open_pg(text)
exec_rounds(conn, 1)
t = now
exec_rounds(conn, ROUNDS)
report('exec_per_row', now - t, ROUNDS * 10_000)

worker = Thread.new do
  exec_rounds(other, ROUNDS)
  nil
end
t = now
exec_rounds(conn, ROUNDS)
both = now - t
worker.join
report('exec_per_row_2_threads', both, ROUNDS * 10_000)

meta = hold(conn)
handle = conn.handle
width = meta[0]
count = meta[1]
types = Kiln::DB::Native.result_types(handle, 1, 1, width)
t = now
row_calls(handle, count, width, ROUNDS)
report('row_call', now - t, ROUNDS * count)

t = now
rows_calls(handle, count, width, ROUNDS)
report('rows_call', now - t, ROUNDS * count)

t = now
meta_calls(handle, ROUNDS * count)
report('locked_ffi_call', now - t, ROUNDS * count)

t = now
token_calls(ROUNDS * count)
report('plain_ffi_call', now - t, ROUNDS * count)

raws = []
lens_list = []
lens = Array.new(width, 0)
r = 0
while r < count
  raws << Kiln::DB::Native.result_row(handle, 1, 1, r, lens)
  lens_list << lens.dup
  r += 1
end
t = now
codec_rounds(raws, lens_list, types, width, ROUNDS)
report('codec_row', now - t, ROUNDS * count)

other_meta = hold(other)
other_handle = other.handle
worker = Thread.new do
  meta_calls(other_handle, ROUNDS * other_meta[1] * 4)
  nil
end
t = now
meta_calls(handle, ROUNDS * count * 4)
both = now - t
worker.join
report('locked_ffi_call_2_threads', both, ROUNDS * count * 4)

worker = Thread.new do
  row_calls(other_handle, other_meta[1], other_meta[0], ROUNDS * 2)
  nil
end
t = now
row_calls(handle, count, width, ROUNDS * 2)
both = now - t
worker.join
report('row_call_2_threads', both, ROUNDS * 2 * count)

worker = Thread.new do
  rows_calls(other_handle, other_meta[1], other_meta[0], ROUNDS * 2)
  nil
end
t = now
rows_calls(handle, count, width, ROUNDS * 2)
both = now - t
worker.join
report('rows_call_2_threads', both, ROUNDS * 2 * count)
conn.close
other.close
print "ok row_transfer\n"
