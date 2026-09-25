#!/usr/bin/env bash
#
# Static regression guard for the PAPPL_MAX_VENDOR=256 source patch.
#
# gutenprint-printer-app.c picks the expert (non-Simplified) Gutenprint PPDs
# only when PAPPL_MAX_VENDOR >= 256 (see gutenprint_autoadd()/main() in
# gutenprint-printer-app.c). In the FSDK build graph, the ceiling is raised
# not in this repository but in the ghostscript-printer-app junction, via
# patches/pappl/printer-application.patch (imported through
# elements/ghostscript-fsdk.bst). If that upstream patch is dropped, or the
# runtime check in this repository's C source is removed, the built image
# silently falls back to the simplified PPDs and the web admin loses non-IPP
# tuning -- with no build failure to flag it. This script fails fast, before
# any OCI build, if that regression happens.
set -euo pipefail

cd "$(dirname "$0")/.."

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

patch_file="$(find . -path '*/patches/pappl/printer-application.patch' -print -quit 2>/dev/null)"
if [[ -z "$patch_file" ]]; then
  fail "could not find patches/pappl/printer-application.patch under the ghostscript-fsdk junction checkout -- has it been fetched (just fetch / bst source fetch)?"
fi
grep -Eq '^\+#\s*define\s+PAPPL_MAX_VENDOR\s+256' "$patch_file" \
  || fail "$patch_file no longer patches PAPPL_MAX_VENDOR to 256"
echo "OK: $patch_file preserves the PAPPL_MAX_VENDOR=256 patch"

grep -Eq 'if\s*\(\s*PAPPL_MAX_VENDOR\s*>=\s*256\s*\)' gutenprint-printer-app.c \
  || fail "gutenprint-printer-app.c no longer branches on PAPPL_MAX_VENDOR >= 256"
grep -q 'CUPS\\\\+Gutenprint' gutenprint-printer-app.c \
  || fail "gutenprint-printer-app.c is missing the expert/simplified driver_display_regex selection"
echo "OK: gutenprint-printer-app.c still selects expert PPDs when PAPPL_MAX_VENDOR >= 256"
