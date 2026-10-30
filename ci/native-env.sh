if [ "$(uname -s)" = Darwin ] && command -v brew >/dev/null 2>&1; then
  for kiln_dependency in libpq mariadb-connector-c libffi openssl@3; do
    kiln_dependency_prefix=$(brew --prefix "$kiln_dependency" 2>/dev/null || true)
    if [ -n "$kiln_dependency_prefix" ] && [ -d "$kiln_dependency_prefix/lib/pkgconfig" ]; then
      case ":${PKG_CONFIG_PATH:-}:" in
        *":$kiln_dependency_prefix/lib/pkgconfig:"*) ;;
        *) PKG_CONFIG_PATH=$kiln_dependency_prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH} ;;
      esac
    fi
  done
  export PKG_CONFIG_PATH
fi

kiln_mariadb_library() {
  case "$(uname -s)" in
    Darwin) kiln_library_name=libmariadb.dylib ;;
    *) kiln_library_name=libmariadb.so ;;
  esac
  for kiln_library_dir in "$1/lib/mariadb" "$1/lib" "$1/lib64/mariadb" "$1/lib64"; do
    if [ -f "$kiln_library_dir/$kiln_library_name" ]; then
      printf '%s\n' "$kiln_library_dir/$kiln_library_name"
      return
    fi
  done
  kiln_library_dir=$(PKG_CONFIG_PATH="$1/lib/pkgconfig:${PKG_CONFIG_PATH:-}" pkg-config --variable=libdir libmariadb 2>/dev/null || true)
  case "$kiln_library_dir" in
    "$1"/*)
      if [ -f "$kiln_library_dir/$kiln_library_name" ]; then
        printf '%s\n' "$kiln_library_dir/$kiln_library_name"
        return
      fi ;;
  esac
  printf 'Connector/C shared library not found under %s\n' "$1" >&2
  return 1
}

kiln_mariadb_env() {
  KILN_DB_LIBMARIADB_PREFIX=$1
  PKG_CONFIG_PATH=$1/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}
  KILN_MARIADB_LIBRARY=$(kiln_mariadb_library "$1")
  export KILN_DB_LIBMARIADB_PREFIX PKG_CONFIG_PATH KILN_MARIADB_LIBRARY
}
