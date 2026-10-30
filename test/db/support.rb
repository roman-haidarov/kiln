def env_line(text, key)
  prefix = "#{key}="
  i = 0
  while i < text.length
    line_end = i
    line_end += 1 while line_end < text.length && text[line_end] != "\n"
    line = text[i, line_end - i]
    return line[prefix.length, line.length - prefix.length] if line.start_with?(prefix)

    i = line_end + 1
  end
  nil
end

def fd_count
  return -1 unless File.directory?('/dev/fd')

  total = 0
  Dir.children('/dev/fd').each do |name|
    next if name.empty?

    numeric = true
    index = 0
    while index < name.bytesize
      char = name[index]
      numeric = false if char < '0' || char > '9'
      index += 1
    end
    total += 1 if numeric
  end
  total
end
