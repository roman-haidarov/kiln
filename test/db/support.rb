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
