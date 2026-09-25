#!/usr/bin/env bash
#
# Static regression guard for the PAPPL_MAX_VENDOR=256 source patch.
#
# gutenprint-printer-app.c picks the expert (non-Simplified) Gutenprint PPDs
# only when PAPPL_MAX_VENDOR >= 256 (see gutenprint_autoadd()/main() in
# gutenprint-printer-app.c). Both packaging recipes patch PAPPL's
# pappl/printer.h to raise the stock 32-option vendor ceiling to 256 before
# the pappl-retrofit/gutenprint-printer-app parts build against it. If either
# patch line disappears, or the runtime check in the C source is removed, the
# built image silently falls back to the simplified PPDs and the web admin
# loses non-IPP tuning -- with no build failure to flag it. This script fails
# fast, before any OCI build, if that regression happens.
set -euo pipefail

cd "$(dirname "$0")/.."

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

check_patch() {
  local file="$1"
  grep -Eq 's/\(define\\s\+PAPPL_MAX_VENDOR\\s\+\)32/\\1 256/' "$file" \
    || fail "$file no longer patches PAPPL_MAX_VENDOR to 256"
  echo "OK: $file preserves the PAPPL_MAX_VENDOR=256 patch"
}

check_patch rockcraft.yaml
check_patch snap/snapcraft.yaml

grep -Eq 'if\s*\(\s*PAPPL_MAX_VENDOR\s*>=\s*256\s*\)' gutenprint-printer-app.c \
  || fail "gutenprint-printer-app.c no longer branches on PAPPL_MAX_VENDOR >= 256"
grep -q 'CUPS\\\\+Gutenprint' gutenprint-printer-app.c \
  || fail "gutenprint-printer-app.c is missing the expert/simplified driver_display_regex selection"
echo "OK: gutenprint-printer-app.c still selects expert PPDs when PAPPL_MAX_VENDOR >= 256"
