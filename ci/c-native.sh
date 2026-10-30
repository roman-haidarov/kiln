#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cc_bin=${KILN_NATIVE_CC:-clang}
link_flags=${KILN_NATIVE_LDFLAGS:-}
artifacts=${KILN_C_ARTIFACTS:-${TMPDIR:-/tmp}/kiln-c-native}
corpus_root=${KILN_C_CORPUS:-${TMPDIR:-/tmp}/kiln-corpus}
fuzz_seconds=${KILN_FUZZ_SECONDS:-2}
run_dir=$(mktemp -d "${TMPDIR:-/tmp}/kiln-c-native.XXXXXX")
corpus_restore=
corpus_backup=
mkdir -p "$artifacts" "$artifacts/crashes" "$corpus_root"
cleanup() {
  if [ -n "$corpus_restore" ] && [ -n "$corpus_backup" ] && [ -d "$corpus_backup" ] && [ ! -e "$corpus_restore" ]; then
    mv "$corpus_backup" "$corpus_restore"
  fi
  rm -rf "$run_dir"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

case $fuzz_seconds in
  ''|*[!0-9]*|0)
    printf 'KILN_FUZZ_SECONDS must be a positive integer\n' >&2
    exit 2
    ;;
esac

find_tool() {
  requested=$1
  fallback=$2
  if [ -n "$requested" ]; then
    printf '%s\n' "$requested"
    return
  fi
  versioned=${fallback}-18
  if command -v "$versioned" >/dev/null 2>&1; then
    command -v "$versioned"
    return
  fi
  command -v "$fallback"
}

spinel_headers() {
  if [ -n "${SPINEL_HDR_DIR:-}" ] && [ -f "$SPINEL_HDR_DIR/spinel/runtime.h" ]; then
    printf '%s\n' "$SPINEL_HDR_DIR"
    return
  fi
  spinel=${SPINEL:-}
  if [ -z "$spinel" ]; then
    prefix=$(./ci/build-spinel.sh) || return 1
    spinel=$prefix/bin/spinel
  fi
  spinel_path=$(command -v "$spinel" 2>/dev/null || true)
  [ -n "$spinel_path" ] || return 1
  spinel_dir=$(cd "$(dirname "$spinel_path")" && pwd -P)
  if [ -L "$spinel_path" ]; then
    link=$(readlink "$spinel_path")
    case $link in
      /*) spinel_dir=$(cd "$(dirname "$link")" && pwd -P) ;;
      *) spinel_dir=$(cd "$spinel_dir/$(dirname "$link")" && pwd -P) ;;
    esac
  fi
  for candidate in "$spinel_dir/lib" "$spinel_dir/../lib" "$spinel_dir/../lib/spinel/lib"; do
    if [ -f "$candidate/spinel/runtime.h" ]; then
      (cd "$candidate" && pwd -P)
      return
    fi
  done
  return 1
}

run_analyze() {
  headers=$(spinel_headers || true)
  sources="kiln_http kiln_uv kiln_uv_parse kiln_tls kiln_sock kiln_ws kiln_cache"
  include="-I$root/ext -I$root/ext/libuv/include -D_GNU_SOURCE -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE"
  if [ -n "$headers" ]; then
    sources="$sources kiln_json kiln_gzip"
    include="$include -I$headers"
  else
    printf 'Spinel headers unavailable; analyzing parser and event parse sources only\n'
  fi
  for source in $sources; do
    log="$artifacts/$source-analyzer.log"
    plist="$artifacts/$source-analyzer.plist"
    if ! "$cc_bin" --analyze -std=c11 -DSP_THREADS $include "$root/ext/$source.c" \
      -o "$plist" >"$log" 2>&1; then
      cat "$log" >&2
      return 1
    fi
    if [ -s "$log" ]; then
      cat "$log" >&2
      return 1
    fi
  done
  printf 'Clang Static Analyzer passed for %s\n' "$sources"
}

write_seed() {
  dir=$1
  name=$2
  value=$3
  mkdir -p "$dir"
  printf '%b' "$value" > "$dir/$name"
}

minimize_corpus() {
  name=$1
  binary=$2
  max_len=$3
  corpus="$corpus_root/$name"
  merged="$run_dir/merged-$name"
  log="$artifacts/$name-merge.log"
  mkdir -p "$merged"
  if ! LLVM_PROFILE_FILE="$run_dir/$name-merge-%p.profraw" "$binary" -merge=1 \
    -max_len="$max_len" -timeout=5 "$merged" "$corpus" > "$log" 2>&1; then
    cat "$log" >&2
    return 1
  fi
  before=$(find "$corpus" -type f | wc -l | tr -d ' ')
  corpus_restore=$corpus
  corpus_backup="$run_dir/original-$name"
  mv "$corpus" "$corpus_backup"
  if mv "$merged" "$corpus"; then
    rm -rf "$corpus_backup"
    corpus_restore=
    corpus_backup=
  else
    mv "$corpus_backup" "$corpus"
    corpus_restore=
    corpus_backup=
    return 1
  fi
  after=$(find "$corpus" -type f | wc -l | tr -d ' ')
  printf 'corpus %s: %s -> %s files\n' "$name" "$before" "$after"
}

run_fuzz_target() {
  name=$1
  source=$2
  max_len=$3
  corpus="$corpus_root/$name"
  mkdir -p "$corpus"
  binary="$run_dir/fuzz-$name"
  profile="$run_dir/$name-%p.profraw"
  log="$artifacts/$name-libfuzzer.log"
  shift 3
  "$cc_bin" -std=c11 -O1 -g -DSP_THREADS -I "$root/ext" \
    -fsanitize=fuzzer,address,undefined -fno-sanitize-recover=undefined -fno-omit-frame-pointer \
    -fprofile-instr-generate -fcoverage-mapping "$source" "$@" $link_flags -o "$binary"
  if ! LLVM_PROFILE_FILE="$profile" "$binary" -seed=1 -max_total_time="$fuzz_seconds" \
    -max_len="$max_len" -timeout=5 -dict="$root/bench/http.dict" \
    -artifact_prefix="$artifacts/crashes/$name-" "$corpus" > "$log" 2>&1; then
    cat "$log" >&2
    return 1
  fi
  printf 'libFuzzer passed: %s (%s seconds)\n' "$name" "$fuzz_seconds"
  minimize_corpus "$name" "$binary" "$max_len"
}

write_seeds() {
  write_seed "$corpus_root/http-kind-0" get 'GET / HTTP/1.1\r\nHost: example.test'
  write_seed "$corpus_root/http-kind-0" post 'POST /items HTTP/1.1\r\nHost: example.test\r\nContent-Length: 4'
  write_seed "$corpus_root/http-kind-1" size '100000'
  write_seed "$corpus_root/http-kind-2" quality 'gzip;q=0.5, br'
  write_seed "$corpus_root/http-kind-3" token 'keep-alive'
  write_seed "$corpus_root/http-kind-4" control 'clean'
  write_seed "$corpus_root/http-kind-5" content_length '1048576'
  write_seed "$corpus_root/http-kind-6" host 'example.test:8080'
  for target in uv-parse uv-parse-diff; do
    dir="$corpus_root/$target"
    mkdir -p "$dir"
    awk 'BEGIN { printf "%c", 4; for (i = 0; i < 16385; i++) printf "A" }' > "$dir/oversized-head"
    write_seed "$dir" request '\0004POST /items HTTP/1.1\r\nHost: example.test\r\nConnection: close, keep-alive\r\nContent-Length: 4\r\n\r\ndata'
    write_seed "$dir" expect '\0004POST /items HTTP/1.1\r\nHost: example.test\r\nExpect: 100-continue\r\nContent-Length: 4\r\n\r\n'
    write_seed "$dir" bad_expect '\0004POST /items HTTP/1.1\r\nHost: example.test\r\nExpect: later\r\n\r\n'
    write_seed "$dir" unsupported '\0004POST /items HTTP/1.1\r\nHost: example.test\r\nTransfer-Encoding: gzip, chunked\r\n\r\n'
    write_seed "$dir" chunked '\0004POST /items HTTP/1.1\r\nHost: example.test\r\nTransfer-Encoding: chunked\r\n\r\n'
    write_seed "$dir" upgrade '\0004GET /ws HTTP/1.1\r\nHost: example.test\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n'
    write_seed "$dir" invalid_length '\0004POST /items HTTP/1.1\r\nHost: example.test\r\nContent-Length: 4x\r\n\r\n'
    write_seed "$dir" oversized '\0004POST /items HTTP/1.1\r\nHost: example.test\r\nContent-Length: 1048577\r\n\r\n'
  done
  write_seed "$corpus_root/uv-chunk" body '\0003\00055\r\nhello\r\n3;x=1\r\nabc\r\n0\r\nX-Sum: 8\r\n\r\n'
  write_seed "$corpus_root/uv-chunk" partial '\0007\0002a\r\n0123'
  write_seed "$corpus_root/uv-chunk" trailer '\0001\00010\r\nTrailer: x\r\n\r\n'
}

run_fuzz() {
  profdata=$(find_tool "${LLVM_PROFDATA:-}" llvm-profdata)
  cov=$(find_tool "${LLVM_COV:-}" llvm-cov)
  write_seeds
  seed_binary="$run_dir/http_seed_check"
  "$cc_bin" -std=c11 -O1 -g -DSP_THREADS -D_GNU_SOURCE -I "$root/ext" \
    -fsanitize=address,undefined -fno-omit-frame-pointer \
    "$root/bench/http_seed_check.c" "$root/ext/kiln_http.c" \
    "$root/ext/kiln_uv_parse.c" "$root/ext/picohttpparser/picohttpparser.c" -o "$seed_binary"
  "$seed_binary" "$corpus_root"
  printf 'HTTP parser and helper seed checks passed\n'
  for kind in 0 1 2 3 4 5 6; do
    run_fuzz_target "http-kind-$kind" "$root/bench/http_fuzz.c" 16384 \
      -DKILN_FUZZ_KIND="$kind" "$root/ext/kiln_http.c" \
      "$root/ext/picohttpparser/picohttpparser.c"
  done
  run_fuzz_target uv-parse "$root/bench/uv_parse_fuzz.c" 32769 \
    "$root/ext/kiln_uv_parse.c" "$root/ext/kiln_http.c" \
    "$root/ext/picohttpparser/picohttpparser.c"
  run_fuzz_target uv-parse-diff "$root/bench/uv_parse_diff_fuzz.c" 32769 \
    "$root/ext/kiln_uv_parse.c" "$root/ext/kiln_http.c" \
    "$root/ext/picohttpparser/picohttpparser.c"
  run_fuzz_target uv-chunk "$root/bench/uv_chunk_fuzz.c" 65536 \
    "$root/ext/kiln_uv_parse.c" "$root/ext/kiln_http.c" \
    "$root/ext/picohttpparser/picohttpparser.c"
  run_fuzz_target cache "$root/bench/cache_fuzz.c" 4096 "$root/ext/kiln_cache.c" -pthread
  sse_target=$(uname -m)
  sse_features=
  if [ "$(uname -s)" = Darwin ]; then
    sse_features=$(sysctl -n machdep.cpu.features 2>/dev/null || true)
  elif [ -r /proc/cpuinfo ]; then
    sse_features=$(grep -im1 '^flags' /proc/cpuinfo || true)
  fi
  if [ "$sse_target" = x86_64 ] && printf '%s' "$sse_features" | grep -Eiq 'sse4[_\.]2'; then
    write_seed "$corpus_root/http-sse-diff" get 'GET / HTTP/1.1\r\nHost: example.test\r\nAccept: */*\r\n\r\n'
    write_seed "$corpus_root/http-sse-diff" post 'POST /items HTTP/1.1\r\nHost: example.test\r\nContent-Length: 4\r\n\r\ndata'
    "$cc_bin" -std=c11 -O1 -g -msse4.2 -DKILN_OPTIMIZED -I "$root/ext" \
      -fsanitize=fuzzer-no-link,address,undefined -fno-omit-frame-pointer \
      -fprofile-instr-generate -fcoverage-mapping \
      -c "$root/ext/kiln_pico_sse42.c" -o "$run_dir/pico_sse42.o"
    run_fuzz_target http-sse-diff "$root/bench/http_sse_diff_fuzz.c" 16384 \
      "$root/ext/picohttpparser/picohttpparser.c" "$run_dir/pico_sse42.o"
  fi
  set -- "$run_dir"/*.profraw
  "$profdata" merge -sparse "$@" -o "$run_dir/fuzz.profdata"
  objects=
  for name in http-kind-0 http-kind-1 http-kind-2 http-kind-3 http-kind-4 http-kind-5 http-kind-6 uv-parse uv-parse-diff uv-chunk; do
    objects="$objects -object=$run_dir/fuzz-$name"
  done
  if [ -x "$run_dir/fuzz-http-sse-diff" ]; then
    objects="$objects -object=$run_dir/fuzz-http-sse-diff"
  fi
  coverage_raw="$artifacts/http-coverage-all.txt"
  "$cov" report "$run_dir/fuzz-http-kind-0" $objects \
    -instr-profile="$run_dir/fuzz.profdata" --show-functions \
    "$root/ext/kiln_http.c" "$root/ext/kiln_uv_parse.c" \
    "$root/ext/picohttpparser/picohttpparser.c" "$root/ext/kiln_pico_sse42.c" > "$coverage_raw"
  awk '
    /^File / || /^Name[[:space:]]/ || /^-+/ { print; next }
    $1 ~ /^(kiln_http_accepts_gzip|kiln_http_scan|kiln_http_scan_at|kiln_scan_request_head|kiln_chunk_size|kiln_token|kiln_ctl|kiln_digits|kiln_host|kiln_uv_parse_request|kiln_http\.c:(kiln_skip_ows|kiln_trim_ows|kiln_gzip_kind|kiln_accept_parameters|kiln_quality|kiln_scan_terminated|kiln_crlf_only|kiln_ascii|kiln_clean_value|kiln_common_index|kiln_tchar|kiln_hex|kiln_ows|kiln_alnum|kiln_subdelim)|kiln_uv_chunk_decode|kiln_uv_parse\.c:(kuv_digits|kuv_has_token|kuv_head_length|kuv_parse_headers|kuv_transfer_coding|kuv_note_field|kuv_check_coding|kuv_is_upgrade_name|kuv_forbidden_trailer|kuv_chunk_line|kuv_chunk_size_line|kuv_chunk_trailer_line))$/ { print }
  ' "$coverage_raw" > "$artifacts/http-coverage.txt"
  cat "$artifacts/http-coverage.txt"
}

run_tsan() {
  binary="$run_dir/http_tsan"
  "$cc_bin" -std=c11 -O1 -g -DSP_THREADS -D_GNU_SOURCE -I "$root/ext" \
    -fsanitize=thread -fno-omit-frame-pointer -pthread \
    "$root/bench/http_tsan.c" "$root/ext/kiln_http.c" $link_flags \
    "$root/ext/picohttpparser/picohttpparser.c" -o "$binary"
  log="$artifacts/http-tsan.log"
  if ! TSAN_OPTIONS=halt_on_error=1 "$binary" > "$log" 2>&1; then
    cat "$log" >&2
    return 1
  fi
  cat "$log"
  tls_binary="$run_dir/tls_tsan"
  tls_dl_flags=
  if [ "$(uname -s)" != Darwin ]; then
    tls_dl_flags=-ldl
  fi
  "$cc_bin" -std=c11 -O1 -g -DSP_THREADS -I "$root/ext" \
    -fsanitize=thread -fno-omit-frame-pointer -pthread \
    "$root/bench/tls_tsan.c" "$root/ext/kiln_tls.c" $link_flags $tls_dl_flags -o "$tls_binary"
  tls_libdir=$(KILN_NATIVE_CC="$cc_bin" "$root/ci/openssl-tsan.sh")
  case $(uname -s) in
    Darwin) tls_ssl="$tls_libdir/libssl.3.dylib"; tls_crypto="$tls_libdir/libcrypto.3.dylib" ;;
    *) tls_ssl="$tls_libdir/libssl.so.3"; tls_crypto="$tls_libdir/libcrypto.so.3" ;;
  esac
  {
    printf 'TLS TSan libraries: %s %s\n' "$tls_ssl" "$tls_crypto"
    if [ -f "$tls_libdir/../build-info.txt" ]; then
      cat "$tls_libdir/../build-info.txt"
    fi
  } | tee "$artifacts/tls-tsan-libraries.txt"
  tls_log="$artifacts/tls-tsan.log"
  tls_lifecycle_log="$artifacts/tls-lifecycle-tsan.log"
  : > "$tls_lifecycle_log"

  if ! (
    export KILN_LIBSSL="$tls_ssl" KILN_LIBCRYPTO="$tls_crypto"
    TSAN_OPTIONS=halt_on_error=1 "$tls_binary" > "$tls_log" 2>&1 || exit 1
    TSAN_OPTIONS=halt_on_error=1 "$tls_binary" \
      "$root/test/fixtures/tls_cert.pem" "$root/test/fixtures/tls_key.pem" > "$tls_lifecycle_log" 2>&1
  ); then
    cat "$tls_log" "$tls_lifecycle_log" >&2
    return 1
  fi
  cat "$tls_log"
  cat "$tls_lifecycle_log"
  cache_log="$artifacts/cache-tsan.log"
  if ! CC="$cc_bin" TSAN_OPTIONS=halt_on_error=1 KILN_CACHE_TEST_DIR="$run_dir/cache-native" \
    "$root/ci/cache-native.sh" tsan > "$cache_log" 2>&1; then
    cat "$cache_log" >&2
    return 1
  fi
  cat "$cache_log"
  CC="$cc_bin" UBSAN_OPTIONS=halt_on_error=1 KILN_CACHE_TEST_DIR="$run_dir/cache-native" \
    "$root/ci/cache-native.sh" asan
  tls_native="$run_dir/tls_lifecycle"
  "$cc_bin" -std=c11 -O2 -DSP_THREADS -I "$root/ext" -pthread \
    "$root/bench/tls_tsan.c" "$root/ext/kiln_tls.c" $link_flags $tls_dl_flags -o "$tls_native"
  "$tls_native" "$root/test/fixtures/tls_cert.pem" "$root/test/fixtures/tls_key.pem"
}

mode=${1:-all}
case $mode in
  analyze)
    run_analyze
    ;;
  fuzz)
    run_fuzz
    ;;
  tsan)
    run_tsan
    ;;
  all)
    run_analyze
    run_fuzz
    run_tsan
    ;;
  *)
    printf 'usage: %s [analyze|fuzz|tsan|all]\n' "$0" >&2
    exit 2
    ;;
esac
