#!/usr/bin/env bash
#
# Static regression guard for the PAPPL_MAX_VENDOR=256 source patch.
#
# gutenprint-printer-app.c picks the expert (non-Simplified) Gutenprint PPDs
# only when PAPPL_MAX_VENDOR >= 256 (see gutenprint_autoadd()/main() in
# gutenprint-printer-app.c). In the FSDK build graph, the ceiling is raised
# not in this repository but in the shared fsdk-containers printing base, via
# patches/printing/pappl/printer-application.patch, imported through the
# pinned junction in elements/fsdk-containers.bst. BuildStream keeps junction
# sources in its own cache, not under this working tree, so this script
# resolves the patch by fetching the exact commit fsdk-containers.bst pins
# and reading the file out of it with `git show`, rather than searching `.`
# for a path that is never actually checked out here. If that upstream patch
# is dropped, or the runtime check in this repository's C source is removed,
# the built image silently falls back to the simplified PPDs and the web
# admin loses non-IPP tuning -- with no build failure to flag it. This
# script fails fast, before any OCI build, if that regression happens.
set -euo pipefail

cd "$(dirname "$0")/.."

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

junction_file="elements/fsdk-containers.bst"
[[ -f "$junction_file" ]] || fail "$junction_file not found"

junction_url="$(sed -n 's/^[[:space:]]*url:[[:space:]]*//p' "$junction_file" | head -n1)"
junction_ref="$(sed -n 's/^[[:space:]]*ref:[[:space:]]*//p' "$junction_file" | head -n1)"
[[ -n "$junction_url" && -n "$junction_ref" ]] \
  || fail "could not read the fsdk-containers junction url/ref from $junction_file"

# junction_url is an alias-relative form ("github:owner/repo.git"); resolve
# it the same way include/aliases.yml does.
junction_repo_url="${junction_url/github:/https:\/\/github.com\/}"

patch_path="patches/printing/pappl/printer-application.patch"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
git -C "$work" init -q
git -C "$work" fetch -q --depth 1 "$junction_repo_url" "$junction_ref" \
  || fail "could not fetch $junction_repo_url at $junction_ref (the pinned fsdk-containers ref)"
patch_file="$work/printer-application.patch"
git -C "$work" show "FETCH_HEAD:$patch_path" > "$patch_file" 2>/dev/null \
  || fail "$junction_repo_url@$junction_ref has no $patch_path -- has the shared printing base dropped or moved the PAPPL_MAX_VENDOR patch?"
grep -Eq '^\+#\s*define\s+PAPPL_MAX_VENDOR\s+256' "$patch_file" \
  || fail "$junction_repo_url@$junction_ref:$patch_path no longer patches PAPPL_MAX_VENDOR to 256"
echo "OK: $junction_repo_url@$junction_ref:$patch_path preserves the PAPPL_MAX_VENDOR=256 patch"

grep -Eq 'if\s*\(\s*PAPPL_MAX_VENDOR\s*>=\s*256\s*\)' gutenprint-printer-app.c \
  || fail "gutenprint-printer-app.c no longer branches on PAPPL_MAX_VENDOR >= 256"
grep -q 'CUPS\\\\+Gutenprint' gutenprint-printer-app.c \
  || fail "gutenprint-printer-app.c is missing the expert/simplified driver_display_regex selection"
echo "OK: gutenprint-printer-app.c still selects expert PPDs when PAPPL_MAX_VENDOR >= 256"
