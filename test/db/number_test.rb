require 'kiln/db'

def toward_zero(left, right)
  q = left / right
  r = left % right
  if r != 0 && (left.negative? != right.negative?)
    q += 1
    r -= right
  end
  [q, r]
end

def check_div(left, right)
  a = Kiln::DB::Int64Value.from_i(left)
  got = a.divmod(right)
  exp = toward_zero(left, right)
  return if got[0].to_i == exp[0] && got[1].to_i == exp[1]

  print 'div-miss '
  print left
  print ' '
  print right
  print "\n"
  raise 'div'
end

def show_err
  yield
  print "no-error\n"
rescue RangeError
  print "RangeError\n"
rescue TypeError
  print "TypeError\n"
rescue ArgumentError
  print "ArgumentError\n"
end

min = Kiln::DB::Int64Value.min_value
max = Kiln::DB::Int64Value.max_value
print min
print "\n"
print max
print "\n"
print min.bind_text
print "\n"
show_err { min.to_i }
print max.to_i
print "\n"
print(min + 1)
print "\n"
print(max + -1)
print "\n"
show_err { max + 1 }
show_err { min + -1 }
show_err { -min }
show_err { min / -1 }
print(min / 1)
print "\n"
print(min / 2)
print "\n"
print(Kiln::DB::Int64Value.from_i(-5) / 2)
print ' '
print(Kiln::DB::Int64Value.from_i(-5) % 2)
print "\n"
print(Kiln::DB::Int64Value.from_i(7) / -3)
print ' '
print(Kiln::DB::Int64Value.from_i(7) % -3)
print "\n"
print(Kiln::DB::Int64Value.from_i(-7) / -2)
print ' '
print(Kiln::DB::Int64Value.from_i(-7) % -2)
print "\n"

pairs = [[1, 1], [5, 2], [-5, 2], [5, -2], [-5, -2], [7, -3], [-7, 2], [-7, -2], [0, 5], [-1, 1], [100, 7], [-100, 7]]
pairs.each { |pair| check_div(pair[0], pair[1]) }
print "div-ok\n"

show_err { Kiln::DB::Int64Value.from_i(nil) }
computed = Kiln::DB::Int64Value.from_i(-9_223_372_036_854_775_807 - 1)
raise 'computed minimum' unless computed == min

print "computed-min\n"
lit = Kiln::DB::Int64Value.from_i(-9_223_372_036_854_775_808)
print lit == min ? "lit-min\n" : "lit-miss\n"
print Kiln::DB::Int64Value.parse('-9223372036854775808') == min ? "parse-min\n" : "parse-miss\n"
print Kiln::DB::Int64Value.parse('9223372036854775807') == max ? "parse-max\n" : "parse-miss\n"
show_err { Kiln::DB::Int64Value.parse('9223372036854775808') }
print (min <=> -9_223_372_036_854_775_809) == 1 ? "cmp-low\n" : "cmp-miss\n"
print (max <=> 9_223_372_036_854_775_808) == -1 ? "cmp-high\n" : "cmp-miss\n"
print Kiln::DB::Int64Value.from_i(-2) < -1 ? "lt-int\n" : "lt-miss\n"
print Kiln::DB::Int64Value.from_i(8) == 8 ? "eq-int\n" : "eq-miss\n"
one = Kiln::DB::Int64Value.from_i(1)
print(-one)
print "\n"
print(one * -3)
print "\n"
print(Kiln::DB::Int64Value.from_i(-3) * -5)
print "\n"
print(Kiln::DB::Int64Value.from_i(1_000_000) * 1_000_000)
print "\n"
show_err { max * 2 }
show_err { min * -1 }
print min * 1 == min ? "min-mul\n" : "min-mul-miss\n"
print(min * 0)
print "\n"
print one.eql?(Kiln::DB::Int64Value.from_i(1)) ? "eql-yes\n" : "eql-no\n"
print one.hash == Kiln::DB::Int64Value.from_i(1).hash ? "hash-eq\n" : "hash-ne\n"
box = {}
box[one] = 1
other = Kiln::DB::Int64Value.from_i(1)
print box[other].nil? ? "hash-key-miss\n" : "hash-key-hit\n"
print box[Kiln::DB::Int64Value.from_i(2)].nil? ? "hash-other-miss\n" : "hash-other-hit\n"
require 'set'
found = Set.new([one])
print found.include?(other) ? "set-hit\n" : "set-miss\n"
print min.to_decimal
print "\n"
print Kiln::DB::ExactDecimal.parse('1.10') == Kiln::DB::ExactDecimal.parse('1.1') ? "dec-eq\n" : "dec-ne\n"
print Kiln::DB::ExactDecimal.parse('1.10') == Kiln::DB::ExactDecimal.parse('1.11') ? "dec-bad\n" : "dec-distinct\n"
print Kiln::DB::ExactDecimal.parse('-0.10')
print "\n"
print Kiln::DB::ExactDecimal.parse('1.10').hash == Kiln::DB::ExactDecimal.parse('1.1').hash ? "dec-hash\n" : "dec-hash-ne\n"
print (Kiln::DB::ExactDecimal.from_i(-4) <=> Kiln::DB::ExactDecimal.parse('1.0')).negative? ? "dec-cmp\n" : "dec-cmp-miss\n"

umax = Kiln::DB::UInt64Value.max_value
print umax
print "\n"
show_err { umax.to_i }
big = Kiln::DB::UInt64Value.parse('9223372036854775808')
show_err { big.to_i }
top = Kiln::DB::UInt64Value.from_i(9_223_372_036_854_775_807)
print top.to_i
print "\n"
print big == 9_223_372_036_854_775_808 ? "u-eq\n" : "u-ne\n"
print big > 9_223_372_036_854_775_807 ? "u-gt\n" : "u-gt-miss\n"
print Kiln::DB::UInt64Value.from_i(1) > -5 ? "u-neg\n" : "u-neg-miss\n"
show_err { umax + 1 }
show_err { Kiln::DB::UInt64Value.from_i(0) - 1 }
print(big / 2)
print "\n"
print(Kiln::DB::UInt64Value.from_i(100) % 7)
print "\n"
show_err { Kiln::DB::UInt64Value.parse('-1') }
show_err { Kiln::DB::Int64Value.from_i(1) < nil }
print Kiln::DB::Errors.code_of('UnsafeImportSchema')
print ' '
print Kiln::DB::Errors.code_of('NonDeterministicQuery')
print "\n"
print "ok number\n"
