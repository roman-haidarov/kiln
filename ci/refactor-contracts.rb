require 'ripper'
require 'digest'

module SourceContracts
  class << self
    def scan(root)
      exports = []
      Dir[File.join(root, 'kiln/**/*.rb')].sort.each do |path|
        tree = Ripper.sexp(File.read(path))
        raise "cannot parse #{path}" unless tree

        walk(tree, '', exports)
      end
      exports.sort
    end

    def walk(node, scope, exports)
      return unless node.is_a?(Array)

      case node[0]
      when :module, :class
        name = constant(node[1])
        nested = scope.empty? ? name : "#{scope}::#{name}"
        walk(node[-1], nested, exports)
      when :command
        name = node[1][1]
        exports << "#{scope} #{normalize(node).inspect}" if %w[ffi_func native_func ffi_lib].include?(name)
        node.each { |child| walk(child, scope, exports) if child.is_a?(Array) }
      else
        node.each { |child| walk(child, scope, exports) if child.is_a?(Array) }
      end
    end

    def constant(node)
      return node[1] if node[0] == :@const
      return "#{constant(node[1])}::#{constant(node[2])}" if node[0] == :const_path_ref

      constant(node[1])
    end

    def normalize(node)
      return node unless node.is_a?(Array)
      return node.first(2) if node[0].is_a?(Symbol) && node[0].to_s.start_with?('@')

      node.map { |child| normalize(child) }
    end

    def native_sources(root)
      files = {}
      Dir[File.join(root, 'ext/**/*.{c,h}')].sort.each do |path|
        relative = path.delete_prefix("#{root}/")
        files[relative] = Digest::SHA256.file(path).hexdigest
      end
      files
    end
  end
end

baseline = SourceContracts.scan(ARGV.fetch(0))
current = SourceContracts.scan(ARGV.fetch(1))
removed = baseline - current
added = current - baseline
raise "native declarations changed: removed=#{removed.inspect}, added=#{added.inspect}" unless removed.empty? && added.empty?

puts "native declarations identical: #{current.length}"
puts "native declaration SHA256: #{Digest::SHA256.hexdigest(current.join("\n"))}"
original_native = SourceContracts.native_sources(ARGV.fetch(0))
current_native = SourceContracts.native_sources(ARGV.fetch(1))
ARGV.drop(2).each do |path|
  original_native.delete(path)
  current_native.delete(path)
end
raise 'native source files changed' unless original_native == current_native

puts "native C/header files identical: #{current_native.length}"
