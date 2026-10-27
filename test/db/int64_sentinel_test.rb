Thread.current

def minimum_text(value)
  raise 'signed minimum' unless value.to_s == '-9223372036854775808'
end

def plain_computed
  n = -9223372036854775807 - 1
  minimum_text(n)
  if n == nil
    print "computed-equals-nil\n"
  else
    print "computed-distinct\n"
  end
end

def plain_literal
  n = -9223372036854775808
  minimum_text(n)
  if n == nil
    print "literal-equals-nil\n"
  else
    print "literal-distinct\n"
  end
end

def slot(flag)
  if flag
    -9223372036854775807 - 1
  end
end

def nilable
  x = slot(true)
  minimum_text(x)
  if x == nil
    print "nilable-equals-nil\n"
  else
    print "nilable-distinct\n"
  end
end

plain_computed
plain_literal
nilable
raise 'missing value' unless slot(false).nil?

print "missing-is-nil\n"
print "ok int64_sentinel\n"
