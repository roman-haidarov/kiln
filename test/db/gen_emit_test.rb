require 'kiln/db'

Thread.current

src = Kiln::DB::Generate.models(:postgres,
                                [{ name: 'kiln_gate_c_user', columns: %w[id name], primary_key: ['id'] }])
print src
print "ok gen-emit\n"
