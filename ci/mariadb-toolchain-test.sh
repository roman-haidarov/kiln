#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$root"
prefix=$(ci/build-mariadb.sh --check)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/kiln-mariadb-test.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
fixture=$scratch/kiln
mkdir -p "$fixture/ci" "$scratch/fake-bin"
cp ci/build-mariadb.sh ci/with-build-lock.rb ci/mariadb-ref ci/mariadb-source.sha256 "$fixture/ci/"
cp -R "$prefix" "$scratch/install"
export KILN_MARIADB_PREFIX=$scratch/install
reject() {
  if "$fixture/ci/build-mariadb.sh" --check > "$scratch/check.log" 2>&1; then
    printf 'FAIL Connector/C accepted %s\n' "$1" >&2
    exit 1
  fi
  printf 'ok Connector/C rejects %s\n' "$1"
}
"$fixture/ci/build-mariadb.sh" --check >/dev/null
printf '\n' >> "$fixture/ci/build-mariadb.sh"
reject 'changed builder'
cp "$root/ci/build-mariadb.sh" "$fixture/ci/"
printf '%040d\n' 0 > "$fixture/ci/mariadb-ref"
reject 'changed revision'
cp "$root/ci/mariadb-ref" "$fixture/ci/"
case "$(uname -s)" in
  Darwin) shared=lib/mariadb/libmariadb.dylib ;;
  *) shared=lib/mariadb/libmariadb.so ;;
esac
printf 'damaged\n' >> "$scratch/install/$shared"
reject 'changed library'
cp -L "$prefix/$shared" "$scratch/install/$shared"
printf '\n' >> "$scratch/install/include/mariadb/mariadb_version.h"
reject 'changed headers'
cp "$prefix/include/mariadb/mariadb_version.h" "$scratch/install/include/mariadb/"
"$fixture/ci/build-mariadb.sh" --check >/dev/null
cat > "$scratch/fake-bin/curl" <<'SH'
#!/bin/sh
while [ "$#" -gt 0 ]; do
  if [ "$1" = --output ]; then
    printf 'corrupted source\n' > "$2"
    exit
  fi
  shift
done
exit 98
SH
cat > "$scratch/fake-bin/cmake" <<'SH'
#!/bin/sh
touch "$KILN_TEST_CMAKE_MARKER"
exit 97
SH
chmod +x "$scratch/fake-bin/curl" "$scratch/fake-bin/cmake"
export KILN_TEST_CMAKE_MARKER=$scratch/cmake-called
printf '%040d\n' 0 > "$fixture/ci/mariadb-ref"
if PATH="$scratch/fake-bin:$PATH" "$fixture/ci/build-mariadb.sh" > "$scratch/build.log" 2>&1; then
  printf 'FAIL Connector/C accepted a corrupted source archive\n' >&2
  exit 1
fi
grep -q 'archive checksum mismatch' "$scratch/build.log"
[ ! -e "$KILN_TEST_CMAKE_MARKER" ]
cmp "$prefix/share/kiln-mariadb/recipe" "$scratch/install/share/kiln-mariadb/recipe"
cmp "$prefix/$shared" "$scratch/install/$shared"
[ ! -d "$scratch/install.lock" ]
printf 'ok Connector/C verifies the archive before cmake and preserves the installation\n'
