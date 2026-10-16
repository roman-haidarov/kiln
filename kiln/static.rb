require 'time'

module Kiln
  module HttpDate
    MONTHS = { 'Jan' => 1, 'Feb' => 2, 'Mar' => 3, 'Apr' => 4, 'May' => 5, 'Jun' => 6,
               'Jul' => 7, 'Aug' => 8, 'Sep' => 9, 'Oct' => 10, 'Nov' => 11, 'Dec' => 12 }.freeze
    IMF = /\A[A-Z][a-z]{2}, (\d{2}) ([A-Z][a-z]{2}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT\z/
    RFC850 = /\A[A-Z][a-z]+, (\d{2})-([A-Z][a-z]{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2}) GMT\z/
    ASCTIME = /\A[A-Z][a-z]{2} ([A-Z][a-z]{2}) ([ \d]\d) (\d{2}):(\d{2}):(\d{2}) (\d{4})\z/
    FORMATS = [[IMF, 3, 2, 1, 4], [RFC850, 3, 2, 1, 4], [ASCTIME, 6, 1, 2, 3]].freeze

    class << self
      def parse(text)
        return nil if text.nil?

        value = text.strip
        FORMATS.each do |pattern, year, month, day, hour|
          found = pattern.match(value)
          next unless found

          full = found[year].to_i
          full = century(full) if pattern == RFC850
          return stamp(found, full, MONTHS[found[month]], found[day].strip.to_i, hour)
        end
        nil
      end

      private

      def stamp(found, year, month, day, hour)
        return nil unless month

        clock = [found[hour].to_i, found[hour + 1].to_i, found[hour + 2].to_i]
        time = Time.utc(year, month, day, clock[0], clock[1], clock[2])
        return nil unless time.month == month && time.day == day && time.hour == clock[0] && time.sec == clock[2]

        time.to_i
      rescue ArgumentError
        nil
      end

      def century(two)
        year = 2000 + two
        year > Time.now.utc.year + 50 ? year - 100 : year
      end
    end
  end

  module Conditional
    SAFE = %w[GET HEAD].freeze
    RANGE = /\Abytes=(\d*)-(\d*)\z/
    LIST_TAG = %r{\G[ \t]*(W/)?("[^\x00-\x20\x22\x7F]*")[ \t]*(?:,|\z)}

    class << self
      def precondition(req, etag, modified)
        heads = req.headers
        return 412 if lost_update?(heads, etag, modified)

        safe = SAFE.include?(req.verb)
        none = heads['if-none-match']
        return (safe ? 304 : 412) if none && tag_listed?(none, etag, strong: false)
        return 200 unless none.nil? && safe

        since = HttpDate.parse(heads['if-modified-since'])
        since && modified <= since ? 304 : 200
      end

      def window(req, etag, modified, size)
        heads = req.headers
        spec = heads['range']
        whole = [0, size, 200]
        return whole if spec.nil? || size.zero? || req.verb != 'GET'
        return whole unless range_fresh?(heads['if-range'], etag, modified)

        found = RANGE.match(spec.strip)
        found ? span(found[1], found[2], size) : whole
      end

      def tag_listed?(list, etag, strong:)
        text = list.strip
        return true if text == '*'
        return false if strong && etag.start_with?('W/')

        own = etag.delete_prefix('W/')
        index = 0
        while index < text.length
          found = LIST_TAG.match(text, index)
          return false unless found
          return true if (!strong || found[1].nil?) && found[2] == own

          index = found.end(0)
        end
        false
      end

      private

      def lost_update?(heads, etag, modified)
        match = heads['if-match']
        return !tag_listed?(match, etag, strong: true) if match

        since = HttpDate.parse(heads['if-unmodified-since'])
        !since.nil? && modified > since
      end

      def range_fresh?(guard, etag, modified)
        return true if guard.nil?

        value = guard.strip
        return value == etag && !etag.start_with?('W/') if value.start_with?('"', 'W/')

        HttpDate.parse(value) == modified
      end

      def span(first, last, size)
        return suffix(last, size) if first.empty?

        from = first.to_i
        return [0, size, 200] if !last.empty? && last.to_i < from
        return [0, 0, 416] if from >= size

        upto = last.empty? ? size - 1 : last.to_i
        upto = size - 1 if upto >= size
        [from, upto - from + 1, 206]
      end

      def suffix(last, size)
        return [0, size, 200] if last.empty?

        count = last.to_i
        return [0, 0, 416] if count.zero?

        count = size if count > size
        [size - count, count, 206]
      end
    end
  end

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

    def initialize(root, param: 'path', index: 'index.html', max_age: nil, dotfiles: false)
      @root = File.realpath(root)
      fd = HttpNative.kiln_http_open_beneath(-1, @root, @root.bytesize)
      raise IOError, "#{root} cannot be opened securely" if fd.negative?

      @root_dir = IO.for_fd(fd)
      unless @root_dir.stat.directory?
        @root_dir.close
        raise ArgumentError, "#{root} is not a directory"
      end

      @prefix = @root.end_with?(SEP) ? @root : "#{@root}#{SEP}"
      @param = param
      @index = index
      @cache = max_age.nil? ? nil : "public, max-age=#{Integer(max_age)}".freeze
      @dotfiles = dotfiles
    end

    def call(ctx)
      file = nil
      path = locate(ctx.req.params[@param].to_s)
      return missing(ctx) unless path

      if path == @root
        path = index_of(path)
        return missing(ctx) unless path
      end
      file = open_path(path)
      return missing(ctx) unless file

      stat = file.stat
      if stat.directory?
        file.close
        file = nil
        path = index_of(path)
        return missing(ctx) unless path

        file = open_path(path)
        return missing(ctx) unless file

        stat = file.stat
      end
      return missing(ctx) unless stat.file?

      file = nil if serve(ctx, path, file, stat) == :stream
    rescue SystemCallError
      missing(ctx)
    ensure
      file.close if file && !file.closed?
    end

    private

    def missing(ctx) = ctx.res.text("not found\n", status: 404)

    def locate(rel)
      return nil if rel.include?("\0") || rel.include?('\\')
      return nil if !@dotfiles && (rel.start_with?('.') || rel.include?('/.'))

      real = File.realpath(rel.empty? ? @root : File.join(@root, rel))
      return nil unless real == @root || real.start_with?(@prefix)
      return nil if !@dotfiles && hidden?(real)

      real
    rescue SystemCallError
      nil
    end

    def index_of(dir)
      return nil if @index.nil?

      found = File.realpath(File.join(dir, @index))
      return nil unless found.start_with?(@prefix)
      return nil if !@dotfiles && hidden?(found)

      found
    rescue SystemCallError
      nil
    end

    def hidden?(path)
      return false if path == @root

      rel = relative(path)
      rel.start_with?('.') || rel.include?('/.')
    end

    def relative(path)
      path.byteslice(@prefix.bytesize, path.bytesize - @prefix.bytesize)
    end

    def open_path(path)
      rel = relative(path)
      fd = HttpNative.kiln_http_open_beneath(@root_dir.fileno, rel, rel.bytesize)
      fd.negative? ? nil : IO.for_fd(fd)
    end

    def serve(ctx, path, file, stat)
      req = ctx.req
      res = ctx.res
      size = stat.size
      modified = stat.mtime.to_i
      changed = stat.ctime
      revision = "#{stat.dev.to_s(16)}-#{stat.ino.to_s(16)}-#{changed.to_i.to_s(16)}"
      etag = %("#{revision}-#{changed.nsec.to_s(16)}-#{stat.mtime.nsec.to_s(16)}-#{size.to_s(16)}")
      stamp(res.headers, path, etag, stat)
      verdict = Conditional.precondition(req, etag, modified)
      unless verdict == 200
        answer_bare(res, verdict, size)
        return nil
      end

      span = Conditional.window(req, etag, modified, size)
      if span[2] == 416
        refuse_range(res, size)
        return nil
      end

      deliver(req, res, file, span, size)
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

    def refuse_range(res, size)
      res.headers['Content-Range'] = "bytes */#{size}"
      res.text('', status: 416)
    end

    def deliver(req, res, file, span, size)
      from, length, status = span
      res.headers['Content-Range'] = "bytes #{from}-#{from + length - 1}/#{size}" if status == 206
      if req.verb != 'HEAD' && length <= WHOLE
        res.status = status
        res.body = slice(file, from, length)
        return nil
      end
      if req.verb == 'HEAD'
        res.stream(status:, length:) { |_out| nil }
        return nil
      end

      res.stream(status:, length:) { |out| copy(file, from, length, out) }
      :stream
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
        chunk = file.read(left < CHUNK ? left : CHUNK)
        break if chunk.nil? || chunk.empty?

        out.write(chunk)
        left -= chunk.bytesize
      end
    ensure
      file.close
    end
  end
end
