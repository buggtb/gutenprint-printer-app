#!/usr/bin/env python3
"""Pick one non-IPP (Gutenprint vendor) <select> option from a PAPPL
"Printing Defaults" web admin page that has a non-default alternative
choice available.

Used by tests/device-settings-web-admin.sh (issue #11) to find a real,
source-backed device setting to flip through the web admin UI, rather
than a hardcoded/synthetic option name that may not exist for every PPD.

Prints "<name> <default_value> <alternative_value>" on success and exits
non-zero if no suitable option is found.
"""
import re
import sys

if len(sys.argv) != 2:
    print("usage: pick-vendor-option.py <html-file>", file=sys.stderr)
    sys.exit(2)

with open(sys.argv[1], encoding="utf-8", errors="replace") as fh:
    html = fh.read()

# These are standard IPP-mapped options PAPPL always renders on this page;
# skip them since issue #11 is specifically about *non-IPP* settings.
ipp_names = {
    "media-source", "media-type", "orientation-requested", "print-color-mode",
    "print-quality", "print-content-optimize", "printer-resolution",
    "output-bin", "sides", "copies", "print-scaling", "print-darkness",
    "print-speed",
}

best = None
for m in re.finditer(r'<select name="([^"]+)">(.*?)</select>', html, re.S):
    name = m.group(1)
    if name in ipp_names or name == "session":
        continue
    body = m.group(2)
    options = re.findall(r'<option value="([^"]*)"( selected)?', body)
    if len(options) < 2:
        continue
    default_val = next((v for v, sel in options if sel), options[0][0])
    alt_val = next((v for v, _ in options if v != default_val), None)
    if alt_val is None:
        continue
    best = (name, default_val, alt_val)
    break

if best is None:
    sys.exit(1)

print(best[0], best[1], best[2])
