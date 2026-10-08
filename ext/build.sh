#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
cc_bin=${CC:-cc}
flags="${KILN_EXT_CFLAGS:--O2} -DSP_THREADS"
compiler_version=$("$cc_bin" --version | sed -n '1p')
build_key=$(printf '%s\n' "$(uname -s)" "$(uname -m)" "$cc_bin" "$compiler_version" "$flags")
mkdir -p build/ext
links=""
rebuild=0
settings=build/ext/settings
if [ ! -f "$settings" ] || [ "$(cat "$settings")" != "$build_key" ]; then
  rebuild=1
fi
for source in ext/picohttpparser/picohttpparser.c ext/kiln_http.c; do
  object=build/ext/$(basename "$source" .c).o
  if [ "$rebuild" -eq 1 ] || [ ! -f "$object" ] || [ "$source" -nt "$object" ] || [ ext/picohttpparser/picohttpparser.h -nt "$object" ]; then
    "$cc_bin" $flags -c "$source" -o "$object"
  fi
  links="$links --link $object"
done
printf '%s\n' "$build_key" > "$settings"
printf '%s\n' "$links"
