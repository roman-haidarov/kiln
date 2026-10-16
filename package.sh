#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
output=${1:-"$root/../kiln.zip"}
mkdir -p "$(dirname "$output")"
output=$(cd -- "$(dirname "$output")" && pwd)/$(basename "$output")
temporary="$output.tmp"
manifest_tool=${KILN_MANIFEST_TOOL:-ruby}
command -v zip >/dev/null 2>&1 || { printf 'missing required tool: zip\n' >&2; exit 1; }

"$manifest_tool" "$root/scripts/make_manifest.rb"
rm -f "$temporary"
(
  cd "$root"
  if [ "${temporary#"$root"/}" != "$temporary" ]; then
    temporary_relative=${temporary#"$root"/}
    find . -type d \( -name .git -o -name build -o -name __pycache__ -o -name .ruby-lsp -o -name validation \) -prune -o \
      -type f ! -name .DS_Store ! -name '._*' ! -name '*.zip' ! -path "./$temporary_relative" -print
  else
    find . -type d \( -name .git -o -name build -o -name __pycache__ -o -name .ruby-lsp -o -name validation \) -prune -o \
      -type f ! -name .DS_Store ! -name '._*' ! -name '*.zip' -print
  fi | sed 's|^\./||' | LC_ALL=C sort | zip -X -q "$temporary" -@
)
mv -f "$temporary" "$output"
printf '%s\n' "$output"
