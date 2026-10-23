Thread.current
def plain_computed
  n = -9223372036854775807 - 1
  if n == nil
    print "computed-equals-nil\n"
  else
    print "computed-distinct\n"
  end
end

def plain_literal
  n = -9223372036854775808
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
  if x == nil
    print "nilable-equals-nil\n"
  else
    print "nilable-distinct\n"
  end
end

plain_computed
plain_literal
nilable
print "ok int64_sentinel\n"
