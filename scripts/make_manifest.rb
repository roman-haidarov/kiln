require 'digest'
require 'find'
require 'fileutils'
require 'json'
require 'pathname'

root = File.expand_path('..', __dir__)
output_dir = ENV.fetch('KILN_VALIDATION_DIR', '/tmp/kiln-validation')
target = File.join(output_dir, 'manifest.json')
skip_dirs = %w[.git build __pycache__ .ruby-lsp validation]
digests = {}

Find.find(root) do |path|
  if File.directory?(path)
    Find.prune if path != root && skip_dirs.include?(File.basename(path))
    next
  end
  name = File.basename(path)
  next if name == '.DS_Store' || name.start_with?('._') || File.extname(path) == '.zip'

  digests[Pathname(path).relative_path_from(Pathname(root)).to_s] = Digest::SHA256.file(path).hexdigest
end

FileUtils.mkdir_p(output_dir)
File.write(target, JSON.pretty_generate(digests.sort.to_h) + "\n")
puts "#{digests.size} files -> #{target}"
