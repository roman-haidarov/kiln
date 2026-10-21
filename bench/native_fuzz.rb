require 'open3'
require 'tempfile'

root = File.expand_path('..', __dir__)
compiler = ENV.fetch('CC') { 'cc' }
source = DATA.read
Tempfile.create(['kiln-native-fuzz-', '.c']) do |file|
  file.write(source)
  file.flush
  binary = "#{file.path}.bin"
  _stdout, stderr, status = Open3.capture3(
    compiler, '-O1', '-g', '-DSP_THREADS', '-fsanitize=address,undefined', '-fno-omit-frame-pointer',
    '-I', File.join(root, 'ext'), file.path, File.join(root, 'ext/kiln_http.c'),
    File.join(root, 'ext/picohttpparser/picohttpparser.c'), '-o', binary
  )
  abort(stderr) unless status.success?
  begin
    stdout, stderr, status = Open3.capture3(binary)
    $stdout.write(stdout)
    $stderr.write(stderr)
    exit(status.exitstatus)
  ensure
    File.delete(binary) if File.file?(binary)
  end
end
__END__
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>

__thread int sp_ffi_bin_len;
long kiln_http_scan(const char *, long, int64_t *, long);
long kiln_http_scan_at(const char *, long, long, long, int64_t *, long);
long kiln_chunk_size(const char *, long, long);

static uint32_t seed = 19112026;
static uint32_t next(void) {
    seed ^= seed << 13;
    seed ^= seed >> 17;
    seed ^= seed << 5;
    return seed;
}

int main(void) {
    const char base[] = "POST /a?q=1 HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\nX-Test: yes";
    char buf[16400];
    int64_t out[505];
    for (long trial = 0; trial < 100000; trial++) {
        long len = sizeof(base) - 1;
        long prefix = next() % 12;
        memset(buf, 'x', sizeof(buf));
        memcpy(buf + prefix, base, len);
        for (long j = 0; j < 1 + trial % 4; j++)
            buf[prefix + next() % len] = (char)next();
        memcpy(buf + prefix + len, "\r\n\r\n", 4);
        long n = kiln_http_scan_at(buf, prefix + len + 4, prefix, len, out, 505);
        if (n >= 0) {
            if (n > 100 || out[0] < prefix || out[0] + out[1] > prefix + len ||
                out[2] < prefix || out[2] + out[3] > prefix + len)
                abort();
            for (long j = 0; j < n; j++) {
                long at = 5 + 5 * j;
                if (out[at] < prefix || out[at] + out[at + 1] > prefix + len ||
                    out[at + 2] < prefix || out[at + 2] + out[at + 3] > prefix + len)
                    abort();
            }
        }
        kiln_http_scan(buf + prefix, len, out, 505);
        kiln_http_scan_at(buf, prefix + len + 4, LONG_MAX, len, out, 505);
        kiln_http_scan_at(buf, 0, 0, len, out, 505);
        kiln_http_scan_at(buf, -1, 0, len, out, 505);
        kiln_http_scan_at(buf, prefix + len + 4, prefix, len, out, next() % 505);
        long size = kiln_chunk_size(buf, prefix + len, LONG_MAX);
        if (size < -2)
            abort();
    }
    puts("native_fuzz cases=100000 ASan+UBSan passed");
    return 0;
}
