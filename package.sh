#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
output=${1:-"$root/../kiln.zip"}
mkdir -p "$(dirname "$output")"
output=$(cd -- "$(dirname "$output")" && pwd)/$(basename "$output")
temporary="$output.tmp"
command -v zip >/dev/null 2>&1 || { printf 'missing required tool: zip\n' >&2; exit 1; }

rm -f "$temporary"
(
  cd "$root"
  if [ -d .git ] && command -v git >/dev/null 2>&1; then
    git ls-files --cached --others --exclude-standard
  else
    find . -type d \( -name .git -o -name build -o -name __pycache__ -o -name .ruby-lsp -o -name validation -o -name __MACOSX -o -path ./ext/croaring \) -prune -o \
      -type f ! -name .DS_Store ! -name '._*' ! -name '*.zip' ! -name '*.tmp' -print |
      sed 's|^\./||'
  fi |
    LC_ALL=C sort -u |
    while IFS= read -r file; do
      [ -f "$file" ] || continue
      case "$file" in
        AGENTS.md|OPEN_QUESTIONS.md|ext/croaring/*|\
        build/*|validation/*|.ruby-lsp/*|.git/*|__MACOSX/*|*/._*|._*|*.DS_Store|*.zip|*.tmp|*.env)
          continue ;;
      esac
      [ "$file" != "${temporary#"$root"/}" ] || continue
      printf '%s\n' "$file"
    done | zip -X -q "$temporary" -@
)
mv -f "$temporary" "$output"
printf '%s\n' "$output"
