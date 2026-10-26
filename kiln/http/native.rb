module Kiln
  module HTTP
    module Native
      CAP = 5 + (5 * Syntax::MAX_HEADERS)
      COMMON = %w[host user-agent accept accept-encoding accept-language connection
                  content-length content-type cookie referer cache-control upgrade-insecure-requests
                  sec-fetch-site sec-fetch-mode sec-fetch-user sec-fetch-dest sec-ch-ua
                  sec-ch-ua-mobile sec-ch-ua-platform origin authorization if-none-match
                  if-modified-since transfer-encoding expect x-forwarded-for x-request-id
                  pragma priority te range dnt].map(&:freeze).freeze

      ffi_func :kiln_http_scan, %i[str long int_array long], :long
      ffi_func :kiln_token, %i[str long], :long
      ffi_func :kiln_peer_closed, [:long], :long
      ffi_func :kiln_peer_closed_uses_rdhup, [], :long
      ffi_func :kiln_recv, %i[long long], :binstr
      ffi_func :kiln_recv_status, [], :long
      ffi_func :kiln_socket_nonblock, [:long], :long
      ffi_func :kiln_sendv, %i[long str long str long long], :long
      ffi_func :kiln_ctl, %i[str long], :long
      ffi_func :kiln_digits, %i[str long], :long
      ffi_func :kiln_chunk_size, %i[str long long], :long
      ffi_func :kiln_chunk_step, %i[str long long long int_array], :binstr
      ffi_func :kiln_host, %i[str long], :long
      ffi_func :kiln_http_scan_at, %i[str long long long int_array long], :long
      ffi_func :kiln_http_byteindex, %i[str long str long long long], :long
      ffi_func :kiln_http_open_beneath, %i[long str long], :long
      ffi_func :kiln_http_accepts_gzip, %i[str long], :long

      class << self
        def scratch = Array.new(CAP, 0)

        def byteindex(data, needle, offset, from)
          Native.kiln_http_byteindex(data, data.bytesize, needle, needle.bytesize, offset, from)
        end

        def parse_head(head, out)
          scanned = Native.kiln_http_scan(head, head.bytesize, out, CAP)
          parsed = scanned.negative? ? nil : build(head, scanned, out)
          parsed || Syntax.parse_head(head)
        end

        def parse_at(data, start, len, out)
          scanned = Native.kiln_http_scan_at(data, data.bytesize, start, len, out, CAP)
          head = data.byteslice(start, len)
          parsed = scanned.negative? ? nil : build(data, scanned, out)
          parsed || Syntax.parse_head(head)
        end

        def build(src, count, out)
          ascii = out[4].anybits?(2)
          verb = owned_slice(src, out[0], out[1], ascii)
          target = owned_slice(src, out[2], out[3], ascii)
          version = out[4].allbits?(1) ? '1.1' : '1.0'
          headers = build_headers(src, count, out, ascii)
          headers && [version, verb, target, headers]
        end

        def token?(text) = Native.kiln_token(text, text.bytesize) == 1
        def ctl?(text) = Native.kiln_ctl(text, text.bytesize) == 1
        def digits?(text) = Native.kiln_digits(text, text.bytesize) == 1
        def host?(text) = Native.kiln_host(text, text.bytesize) == 1

        private

        def build_headers(src, count, out, ascii)
          headers = {}
          index = 0
          while index < count
            offset = 5 + (5 * index)
            value = owned_slice(src, out[offset + 2], out[offset + 3], ascii)
            return nil unless add_header?(headers, header_key(src, out, offset), value, ascii)

            index += 1
          end
          headers
        end

        def header_key(src, out, offset)
          known = out[offset + 4]
          return COMMON[known] if known >= 0

          key = src.byteslice(out[offset], out[offset + 1])
          key.downcase!
          key.force_encoding(Encoding::UTF_8)
        end

        def add_header?(headers, key, value, ascii)
          previous = headers[key]
          if previous.nil?
            headers[key] = value
            return true
          end
          return false if Syntax::SINGLE.include?(key)

          headers[key] = joined_value(previous, value, ascii, key)
          true
        end

        def joined_value(previous, value, ascii, key)
          joined = previous.b
          joined << (key == 'cookie' ? '; '.b : ', '.b)
          joined << value.b
          own!(joined, ascii)
          joined
        end

        def owned_slice(src, from, length, ascii)
          text = src.byteslice(from, length)
          own!(text, ascii)
          text
        end

        def own!(text, ascii)
          text.force_encoding(Encoding::UTF_8)
          text.force_encoding(Encoding::ASCII_8BIT) unless ascii || text.valid_encoding?

          nil
        end
      end
    end
  end
end
