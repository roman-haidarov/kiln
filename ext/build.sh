#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
cc_bin=${CC:-cc}
flags="${KILN_EXT_CFLAGS:--O2} -DSP_THREADS"
compiler_version=$("$cc_bin" --version | sed -n '1p')
if command -v sha256sum > /dev/null 2>&1; then
  hash_tool="sha256sum"
elif command -v shasum > /dev/null 2>&1; then
  hash_tool="shasum -a 256"
else
  hash_tool="cksum"
fi
content_key=$(find ext -type f \( -name '*.c' -o -name '*.h' \) -print | LC_ALL=C sort | xargs $hash_tool | $hash_tool)
build_key=$(printf '%s\n' "$(uname -s)" "$(uname -m)" "$cc_bin" "$compiler_version" "$flags" "$content_key")
mkdir -p build/ext
links=""
rebuild=0
settings=build/ext/settings
if [ ! -f "$settings" ] || [ "$(cat "$settings")" != "$build_key" ]; then
  rebuild=1
fi
for source in ext/picohttpparser/picohttpparser.c ext/kiln_http.c ext/kiln_uv.c ext/uvsrc/*.c; do
  object=build/ext/$(basename "$source" .c).o
  if [ "$rebuild" -eq 1 ] || [ ! -f "$object" ]; then
    "$cc_bin" $flags -c "$source" -o "$object"
  fi
  links="$links --link $object"
done
printf '%s\n' "$build_key" > "$settings"
printf '%s\n' "$links"
