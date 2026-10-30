#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$root"
prefix=$(ci/build-spinel.sh --check)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/kiln-toolchain-test.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
fixture=$scratch/kiln
mkdir -p "$fixture/ci" "$fixture/patches/spinel" "$scratch/fake-bin"
cp ci/build-spinel.sh ci/with-build-lock.rb ci/spinel-cc.sh ci/spinel-ref "$fixture/ci/"
cp patches/spinel/*.patch "$fixture/patches/spinel/" 2>/dev/null || true
cp -R "$prefix" "$scratch/install"
export KILN_SPINEL_PREFIX=$scratch/install

must_reject() {
  if "$fixture/ci/build-spinel.sh" --check > "$scratch/check.log" 2>&1; then
    printf 'FAIL toolchain accepted %s\n' "$1" >&2
    exit 1
  fi
  printf 'ok toolchain rejects %s\n' "$1"
}

"$fixture/ci/build-spinel.sh" --check >/dev/null
printf '\n' >> "$fixture/ci/spinel-cc.sh"
must_reject 'changed compiler wrapper'
cp "$root/ci/spinel-cc.sh" "$fixture/ci/"
printf '\n' >> "$fixture/ci/build-spinel.sh"
must_reject 'changed builder'
cp "$root/ci/build-spinel.sh" "$fixture/ci/"
printf '%040d\n' 0 > "$fixture/ci/spinel-ref"
must_reject 'changed revision'
cp "$root/ci/spinel-ref" "$fixture/ci/"
printf 'broken patch\n' > "$fixture/patches/spinel/extra.patch"
must_reject 'changed patch set'
rm "$fixture/patches/spinel/extra.patch"
mv "$scratch/install/share/kiln-spinel/recipe" "$scratch/recipe"
must_reject 'missing provenance'
mv "$scratch/recipe" "$scratch/install/share/kiln-spinel/recipe"
printf 'damaged runtime\n' >> "$scratch/install/lib/spinel/lib/libspinel_rt_mt.a"
must_reject 'changed runtime archive'
cp "$prefix/lib/spinel/lib/libspinel_rt_mt.a" "$scratch/install/lib/spinel/lib/"
"$fixture/ci/build-spinel.sh" --check >/dev/null

cat > "$scratch/fake-bin/spinel" <<'SH'
#!/bin/sh
exit 99
SH
chmod +x "$scratch/fake-bin/spinel"
PATH="$scratch/fake-bin:$PATH" SPINEL="$scratch/fake-bin/spinel" "$root/bin/spinel" --version >/dev/null
printf 'ok wrapper uses the managed compiler\n'

export KILN_TEST_REAL_GIT=$(command -v git)
export KILN_TEST_SOURCE=$scratch/upstream
export KILN_TEST_MAKE_MARKER=$scratch/make-called
git init -q "$KILN_TEST_SOURCE"
printf 'before\n' > "$KILN_TEST_SOURCE/placement.txt"
git -C "$KILN_TEST_SOURCE" add placement.txt
git -C "$KILN_TEST_SOURCE" -c user.name=Kiln -c user.email=kiln@example.invalid -c commit.gpgsign=false commit -qm fixture
git -C "$KILN_TEST_SOURCE" rev-parse HEAD > "$fixture/ci/spinel-ref"
printf 'after\n' > "$KILN_TEST_SOURCE/placement.txt"
git -C "$KILN_TEST_SOURCE" diff > "$scratch/valid.patch"
git -C "$KILN_TEST_SOURCE" checkout -- placement.txt
for patch in "$fixture"/patches/spinel/*.patch; do
  [ ! -f "$patch" ] || rm "$patch"
done
cat > "$scratch/fake-bin/git" <<'SH'
#!/bin/sh
if [ "${1:-}" = -C ] && [ "${3:-}" = remote ] && [ "${4:-}" = add ] && [ "${5:-}" = origin ]; then
  exec "$KILN_TEST_REAL_GIT" -C "$2" remote add origin "$KILN_TEST_SOURCE"
fi
exec "$KILN_TEST_REAL_GIT" "$@"
SH
cat > "$scratch/fake-bin/make" <<'SH'
#!/bin/sh
git -C "$2" diff --exit-code --quiet && state=clean || state=patched
printf '%s\n' "$state" > "$KILN_TEST_MAKE_MARKER"
exit 97
SH
chmod +x "$scratch/fake-bin/git" "$scratch/fake-bin/make"
export PATH="$scratch/fake-bin:$PATH"
export KILN_SPINEL_PREFIX=$scratch/fresh-install
printf 'invalid patch\n' > "$fixture/patches/spinel/placement.patch"
if "$fixture/ci/build-spinel.sh" > "$scratch/build.log" 2>&1; then
  printf 'FAIL invalid patch was accepted\n' >&2
  exit 1
fi
if [ -e "$KILN_TEST_MAKE_MARKER" ] || [ -e "$KILN_SPINEL_PREFIX" ]; then
  printf 'FAIL build continued after patch rejection\n' >&2
  exit 1
fi
printf 'ok invalid patch stops before make\n'

export KILN_SPINEL_PREFIX=$scratch/install
if "$fixture/ci/build-spinel.sh" > "$scratch/build.log" 2>&1; then
  printf 'FAIL invalid patch replaced the existing installation\n' >&2
  exit 1
fi
"$root/ci/build-spinel.sh" --check >/dev/null
printf 'ok failed update preserves the installed toolchain\n'
export KILN_SPINEL_PREFIX=$scratch/fresh-install

cp "$scratch/valid.patch" "$fixture/patches/spinel/placement.patch"
status=0
"$fixture/ci/build-spinel.sh" > "$scratch/build.log" 2>&1 || status=$?
[ "$status" -eq 97 ] && [ "$(cat "$KILN_TEST_MAKE_MARKER")" = patched ] && [ ! -e "$KILN_SPINEL_PREFIX" ]
printf 'ok patch applies before make and failed make leaves no installation\n'
rm "$fixture/patches/spinel/placement.patch" "$KILN_TEST_MAKE_MARKER"
status=0
"$fixture/ci/build-spinel.sh" > "$scratch/build.log" 2>&1 || status=$?
[ "$status" -eq 97 ] && [ "$(cat "$KILN_TEST_MAKE_MARKER")" = clean ] && [ ! -e "$KILN_SPINEL_PREFIX" ]
printf 'ok empty patch directory selects clean upstream\n'
