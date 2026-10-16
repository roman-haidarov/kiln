#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$root"
dry_run=0

case "${1:-}" in
  '')
    ;;
  --dry-run)
    dry_run=1
    ;;
  --help)
    printf 'Usage: %s [--dry-run]\n' "$0"
    printf 'Removes build outputs, the Ruby LSP cache, dSYM bundles, core dumps, and Finder metadata.\n'
    exit 0
    ;;
  *)
    printf 'Usage: %s [--dry-run]\n' "$0" >&2
    exit 2
    ;;
esac

remove_path() {
  path=$1
  if [ -e "$path" ] || [ -L "$path" ]; then
    if [ "$dry_run" -eq 1 ]; then
      printf 'would remove %s\n' "$path"
    else
      rm -rf "$path"
      printf 'removed %s\n' "$path"
    fi
  fi
}

remove_path build
remove_path .ruby-lsp

if [ "$dry_run" -eq 1 ]; then
  find . -path './.git' -prune -o -path './build' -prune -o -path './.ruby-lsp' -prune \
    -o \( -type d -name '*.dSYM' -o -type f \( -name '*.core' -o -name '.DS_Store' \) \) -print
else
  find . -depth -path './.git' -prune -o -path './build' -prune -o -path './.ruby-lsp' -prune \
    -o \( -type d -name '*.dSYM' -o -type f \( -name '*.core' -o -name '.DS_Store' \) \) -exec rm -rf {} +
fi
