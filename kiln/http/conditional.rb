module Kiln
  module HTTP
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
          return none_match_status(none, etag, safe) if none
          return 200 unless safe

          not_modified?(heads, modified) ? 304 : 200
        end

        def window(req, etag, modified, size)
          spec = req.headers['range']
          whole = [0, size, 200]
          return whole unless spec && rangeable?(req, size, etag, modified)

          range_span(spec, size, whole)
        end

        def tag_listed?(list, etag, strong:)
          text = list.strip
          return true if text == '*'
          return false if strong && etag.start_with?('W/')

          tags_include?(text, etag.delete_prefix('W/'), strong)
        end

        private

        def none_match_status(none, etag, safe)
          return 200 unless tag_listed?(none, etag, strong: false)

          safe ? 304 : 412
        end

        def not_modified?(heads, modified)
          since = HTTP::Date.parse(heads['if-modified-since'])
          !since.nil? && modified <= since
        end

        def rangeable?(req, size, etag, modified)
          size.positive? && req.verb == 'GET' && range_fresh?(req.headers['if-range'], etag, modified)
        end

        def range_span(spec, size, whole)
          found = RANGE.match(spec.strip)
          found ? span(found[1], found[2], size) : whole
        end

        def tags_include?(text, own, strong)
          index = 0
          while index < text.length
            found = LIST_TAG.match(text, index)
            return false unless found
            return true if (!strong || found[1].nil?) && found[2] == own

            index = found.end(0)
          end
          false
        end

        def lost_update?(heads, etag, modified)
          match = heads['if-match']
          return !tag_listed?(match, etag, strong: true) if match

          since = HTTP::Date.parse(heads['if-unmodified-since'])
          !since.nil? && modified > since
        end

        def range_fresh?(guard, etag, modified)
          return true if guard.nil?

          value = guard.strip
          return value == etag && !etag.start_with?('W/') if value.start_with?('"', 'W/')

          HTTP::Date.parse(value) == modified
        end

        def span(first, last, size)
          return suffix(last, size) if first.empty?

          from = first.to_i
          return [0, size, 200] if reversed?(from, last)
          return [0, 0, 416] if from >= size

          [from, bounded_end(last, size) - from + 1, 206]
        end

        def reversed?(from, last) = !last.empty? && last.to_i < from

        def bounded_end(last, size)
          end_at = last.empty? ? size - 1 : last.to_i
          end_at >= size ? size - 1 : end_at
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
  end
end
