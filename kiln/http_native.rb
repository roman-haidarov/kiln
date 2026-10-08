module Kiln
  module HttpNative
    CAP = 5 + 5 * HttpSyntax::MAX_HEADERS
    COMMON = %w[host user-agent accept accept-encoding accept-language connection
                content-length content-type cookie referer cache-control upgrade-insecure-requests
                sec-fetch-site sec-fetch-mode sec-fetch-user sec-fetch-dest sec-ch-ua
                sec-ch-ua-mobile sec-ch-ua-platform origin authorization if-none-match
                if-modified-since transfer-encoding expect x-forwarded-for x-request-id
                pragma priority te range dnt].map(&:freeze).freeze

    ffi_func :kiln_http_scan, [:str, :long, :int_array, :long], :long
    ffi_func :kiln_token, [:str, :long], :long
    ffi_func :kiln_peer_closed, [:long], :long
    ffi_func :kiln_peer_closed_uses_rdhup, [], :long
    ffi_func :kiln_recv, [:long, :long], :binstr
    ffi_func :kiln_recv_status, [], :long
    ffi_func :kiln_send, [:long, :str, :long, :long, :long], :long
    ffi_func :kiln_ctl, [:str, :long], :long
    ffi_func :kiln_digits, [:str, :long], :long
    ffi_func :kiln_chunk_size, [:str, :long, :long], :long
    ffi_func :kiln_host, [:str, :long], :long
    ffi_func :kiln_http_scan_at, [:str, :long, :long, :long, :int_array, :long], :long

    class << self
      def scratch = Array.new(CAP, 0)

      def parse_head(head, out)
        n = HttpNative.kiln_http_scan(head, head.bytesize, out, CAP)
        return HttpSyntax.parse_head(head) if n < 0
        build(head, n, out) || HttpSyntax.parse_head(head)
      end

      def parse_at(data, start, len, out)
        n = HttpNative.kiln_http_scan_at(data, data.bytesize, start, len, out, CAP)
        return HttpSyntax.parse_head(data.byteslice(start, len)) if n < 0
        build(data, n, out) || HttpSyntax.parse_head(data.byteslice(start, len))
      end

      def build(src, n, out)
        ascii = (out[4] & 2) != 0
        verb = owned(src.byteslice(out[0], out[1]), ascii)
        target = owned(src.byteslice(out[2], out[3]), ascii)
        version = (out[4] & 1) == 1 ? "1.1" : "1.0"
        headers = {}
        i = 0
        o = 5
        while i < n
          known = out[o + 4]
          if known >= 0
            key = COMMON[known]
          else
            key = src.byteslice(out[o], out[o + 1])
            key.downcase!
            key.force_encoding(Encoding::UTF_8)
          end
          value = owned(src.byteslice(out[o + 2], out[o + 3]), ascii)
          if headers.key?(key)
            return nil if HttpSyntax::SINGLE.include?(key)
            joined = headers[key].b
            joined << ", ".b
            joined << value.b
            headers[key] = owned(joined, ascii)
          else
            headers[key] = value
          end
          i += 1
          o += 5
        end
        [version, verb, target, headers]
      end

      def token?(text) = HttpNative.kiln_token(text, text.bytesize) == 1
      def ctl?(text) = HttpNative.kiln_ctl(text, text.bytesize) == 1
      def digits?(text) = HttpNative.kiln_digits(text, text.bytesize) == 1
      def host?(text) = HttpNative.kiln_host(text, text.bytesize) == 1

      private

      def owned(text, ascii)
        text.force_encoding(Encoding::UTF_8)
        return text if ascii
        text.valid_encoding? ? text : text.force_encoding(Encoding::ASCII_8BIT)
      end
    end
  end
end
