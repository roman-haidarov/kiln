require 'time'

module Kiln
  class Static
    TYPES = {
      '.html' => 'text/html; charset=utf-8', '.htm' => 'text/html; charset=utf-8',
      '.css' => 'text/css; charset=utf-8', '.js' => 'text/javascript; charset=utf-8',
      '.mjs' => 'text/javascript; charset=utf-8', '.json' => 'application/json',
      '.txt' => 'text/plain; charset=utf-8', '.md' => 'text/markdown; charset=utf-8',
      '.csv' => 'text/csv; charset=utf-8', '.xml' => 'application/xml', '.svg' => 'image/svg+xml',
      '.png' => 'image/png', '.jpg' => 'image/jpeg', '.jpeg' => 'image/jpeg', '.gif' => 'image/gif',
      '.webp' => 'image/webp', '.avif' => 'image/avif', '.ico' => 'image/vnd.microsoft.icon',
      '.woff' => 'font/woff', '.woff2' => 'font/woff2', '.ttf' => 'font/ttf', '.otf' => 'font/otf',
      '.pdf' => 'application/pdf', '.wasm' => 'application/wasm', '.map' => 'application/json',
      '.mp4' => 'video/mp4', '.webm' => 'video/webm', '.mp3' => 'audio/mpeg', '.ogg' => 'audio/ogg',
      '.wav' => 'audio/wav', '.zip' => 'application/zip', '.gz' => 'application/gzip'
    }.freeze
    OCTETS = 'application/octet-stream'.freeze
    TYPE = 'Content-Type'.freeze
    MODIFIED = 'Last-Modified'.freeze
    TAG = 'ETag'.freeze
    RANGES = 'Accept-Ranges'.freeze
    BYTES = 'bytes'.freeze
    CACHE = 'Cache-Control'.freeze
    WHOLE = 256 * 1024
    CHUNK = 64 * 1024
    SEP = '/'.freeze

    module Locating
      private

      def locate(rel)
        return nil unless safe_relative?(rel)

        real = File.realpath(rel.empty? ? @root : File.join(@root, rel))
        return nil unless real == @root || real.start_with?(@prefix)

        visible?(real) ? real : nil
      rescue SystemCallError
        nil
      end

      def index_of(dir)
        return nil if @index.nil?

        found = File.realpath(File.join(dir, @index))
        found.start_with?(@prefix) && visible?(found) ? found : nil
      rescue SystemCallError
        nil
      end

      def safe_relative?(rel)
        return false if rel.include?("\0") || rel.include?('\\')

        @dotfiles || !dotted?(rel)
      end

      def visible?(path) = @dotfiles || path == @root || !dotted?(relative(path))
      def dotted?(rel) = rel.start_with?('.') || rel.include?('/.')

      def relative(path)
        path.byteslice(@prefix.bytesize, path.bytesize - @prefix.bytesize)
      end

      def open_path(path)
        rel = relative(path)
        fd = HTTP::Native.kiln_http_open_beneath(@root_dir.fileno, rel, rel.bytesize)
        fd.negative? ? nil : IO.for_fd(fd)
      end

      def start_path(rel)
        path = locate(rel)
        path == @root ? index_of(path) : path
      end

      def into_index(path, file, opened)
        return [path, file] unless file.stat.directory?

        file.close
        index = index_of(path)
        [index, index ? track(opened, open_path(index)) : nil]
      end

      def track(opened, file)
        opened << file if file
        file
      end
    end

    module Serving
      private

      def serve(ctx, path, file, stat)
        req = ctx.req
        res = ctx.res
        size = stat.size
        etag = entity_tag(stat)
        modified = stat.mtime.to_i
        stamp(res.headers, path, etag, stat)
        verdict = HTTP::Conditional.precondition(req, etag, modified)
        return answer_bare(res, verdict, size) unless verdict == 200

        deliver_window(req, res, file, HTTP::Conditional.window(req, etag, modified, size), size)
      end

      def entity_tag(stat)
        changed = stat.ctime
        revision = "#{stat.dev.to_s(16)}-#{stat.ino.to_s(16)}-#{changed.to_i.to_s(16)}"
        %("#{revision}-#{changed.nsec.to_s(16)}-#{stat.mtime.nsec.to_s(16)}-#{stat.size.to_s(16)}")
      end

      def stamp(headers, path, etag, stat)
        headers[TYPE] = TYPES[File.extname(path).downcase] || OCTETS
        headers[MODIFIED] = stat.mtime.httpdate
        headers[TAG] = etag
        headers[RANGES] = BYTES
        headers[CACHE] = @cache if @cache
      end

      def answer_bare(res, status, size)
        if status == 304
          res.note_representation(size, res.headers[TYPE])
          res.headers.delete(TYPE)
        end
        res.status = status
        res.body = ''
      end

      def deliver_window(req, res, file, span, size)
        return refuse_range(res, size) if span[2] == 416

        deliver(req, res, file, span, size)
      end

      def refuse_range(res, size)
        res.headers['Content-Range'] = "bytes */#{size}"
        res.text('', status: 416)
        nil
      end

      def deliver(req, res, file, span, size)
        from, length, status = span
        res.headers['Content-Range'] = "bytes #{from}-#{from + length - 1}/#{size}" if status == 206
        return deliver_head(res, status, length) if req.verb == 'HEAD'
        return deliver_whole(res, status, slice(file, from, length)) if length <= WHOLE

        res.stream(status:, length:) { |out| copy(file, from, length, out) }
        :stream
      end

      def deliver_head(res, status, length)
        res.stream(status:, length:) { |_out| nil }
        nil
      end

      def deliver_whole(res, status, body)
        res.status = status
        res.body = body
        nil
      end

      def slice(file, from, length)
        file.seek(from) if from.positive?
        return ''.b if length.zero?

        file.read(length) || ''.b
      end

      def copy(file, from, length, out)
        file.seek(from) if from.positive?
        left = length
        while left.positive?
          chunk = file.read([left, CHUNK].min)
          break if chunk.nil? || chunk.empty?

          out.write(chunk)
          left -= chunk.bytesize
        end
      ensure
        file.close
      end
    end

    include Locating
    include Serving

    def initialize(root, param: 'path', index: 'index.html', max_age: nil, dotfiles: false)
      @root = File.realpath(root)
      @root_dir = open_root(root)
      @prefix = @root.end_with?(SEP) ? @root : "#{@root}#{SEP}"
      @param = param
      @index = index
      @cache = max_age.nil? ? nil : "public, max-age=#{Integer(max_age)}".freeze
      @dotfiles = dotfiles
    end

    def call(ctx)
      opened = []
      respond(ctx, opened)
    rescue SystemCallError
      missing(ctx)
    ensure
      opened.each { |file| file.close unless file.closed? }
    end

    private

    def open_root(root)
      fd = HTTP::Native.kiln_http_open_beneath(-1, @root, @root.bytesize)
      raise IOError, "#{root} cannot be opened securely" if fd.negative?

      dir = IO.for_fd(fd)
      return dir if dir.stat.directory?

      dir.close
      raise ArgumentError, "#{root} is not a directory"
    end

    def respond(ctx, opened)
      path = start_path(ctx.req.params[@param].to_s)
      file = path ? track(opened, open_path(path)) : nil
      return missing(ctx) unless file

      path, file = into_index(path, file, opened)
      stat = file&.stat
      return missing(ctx) unless stat&.file?

      opened.clear if serve(ctx, path, file, stat) == :stream
    end

    def missing(ctx) = ctx.res.text("not found\n", status: 404)
  end
end
