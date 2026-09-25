#!/usr/bin/env bash
#
# Real-image verification that expert Gutenprint PPDs and their PAPPL
# vendor-option budget are actually exposed and honoured by the shipped
# image (issue #9).
#
# The CI workflow builds the real rock and loads it into podman, passing it
# via $IMAGE. This script then, against that running image only (no mock
# echoes, no synthetic PPD parsing):
#
#   1. Confirms the image registers an expert (non-"Simplified") Gutenprint
#      driver -- i.e. PAPPL_MAX_VENDOR >= 256 actually took effect for this
#      build, per the driver_display_regex selection in
#      gutenprint-printer-app.c.
#   2. Adds a printer with that driver and confirms `options` reports more
#      than 32 vendor/job options -- proving the raised PAPPL vendor-option
#      ceiling, not just the simplified 32-option PPD set, is in force.
#   3. Picks one supported non-default vendor option value, submits a print
#      job with it set, and diffs the bytes captured at the socket sink
#      against a baseline job printed with defaults -- proving the option
#      change reaches the real filter output, not just the job ticket.
set -euo pipefail

IMAGE="${IMAGE:-ghcr.io/projectbluefin/gutenprint-printer-app:build}"
NAME="gutenprint-printer-app-vendor-options"
PORT="${PORT:-18100}"
SINK_PORT="$((PORT + 1))"
STATE_DIR="$(mktemp -d)"
BASELINE_SINK="$(mktemp)"
CHANGED_SINK="$(mktemp)"
SINK_PID=""

cleanup() {
  podman rm -f "$NAME" >/dev/null 2>&1 || true
  if [[ -n "$SINK_PID" ]]; then
    kill "$SINK_PID" >/dev/null 2>&1 || true
    wait "$SINK_PID" 2>/dev/null || true
  fi
  podman unshare rm -rf "$STATE_DIR" 2>/dev/null || true
  rm -f "$BASELINE_SINK" "$CHANGED_SINK"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# --- pick an expert (non-Simplified) Gutenprint driver ----------------------
pick_expert_driver() {
  local drivers driver
  drivers="$(podman run --rm --entrypoint /usr/bin/bash "$IMAGE" -c \
    'gutenprint-printer-app drivers 2>/dev/null' || true)"
  # Expert PPDs are named "... - CUPS+Gutenprint <version> <model>", the
  # simplified ones carry a trailing "Simplified" marker (see
  # driver_display_regex in gutenprint-printer-app.c).
  driver="$(printf '%s\n' "$drivers" \
    | grep -Ei 'CUPS\+Gutenprint' \
    | grep -Eiv 'simplified' \
    | head -n1 || true)"
  printf '%s' "$driver" | sed -E 's/^([^ ]+).*/\1/'
}

DRIVER="$(pick_expert_driver)"
if [[ -z "$DRIVER" ]]; then
  echo "Full driver list for diagnosis:" >&2
  podman run --rm --entrypoint /usr/bin/bash "$IMAGE" -c \
    'gutenprint-printer-app drivers 2>/dev/null' >&2 || true
  fail "no expert (non-Simplified) CUPS+Gutenprint driver found -- PAPPL_MAX_VENDOR patch did not take effect in this image"
fi
echo "Using expert driver: $DRIVER"

chmod 0777 "$STATE_DIR"

# --- start the image --------------------------------------------------------
podman run -d \
  --name "$NAME" \
  --network host \
  -e PORT="$PORT" \
  -v "$STATE_DIR:/var/lib/gutenprint-printer-app:Z" \
  "$IMAGE" >/dev/null

ready=0
for _ in $(seq 1 120); do
  if curl --fail --silent --show-error "http://127.0.0.1:${PORT}/" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
[[ "$ready" -eq 1 ]] || { podman logs "$NAME" >&2 || true; fail "web server did not become ready"; }

PRINTER="vendor-options-test"
PRINTER_URI="ipp://127.0.0.1:${PORT}/ipp/print/${PRINTER}"
podman exec "$NAME" gutenprint-printer-app \
  -u "cups:socket://127.0.0.1:${SINK_PORT}" \
  -d "$PRINTER" \
  -m "$DRIVER" \
  add

# --- confirm the vendor-option budget is actually available ----------------
options_output="$(podman exec "$NAME" gutenprint-printer-app -u "$PRINTER_URI" options)"
option_count="$(printf '%s\n' "$options_output" | grep -Ec '^[[:space:]]*-o ')"
echo "Reported $option_count '-o' option lines for $DRIVER"
[[ "$option_count" -gt 32 ]] \
  || fail "only $option_count options reported; expected more than 32 (PAPPL_MAX_VENDOR budget not exposed)"

# --- pick one non-default vendor option value to flip -----------------------
# Look for a Gutenprint-specific keyword option (skip the generic IPP-ish
# ones already covered by issue #6's core payload test) with at least one
# alternative to its default.
read -r opt_name opt_default opt_alt < <(printf '%s\n' "$options_output" | awk '
  /^[[:space:]]*-o [A-Za-z0-9_-]+=.*\(default\)/ {
    line=$0
    sub(/^[[:space:]]*-o /, "", line)
    split(line, kv, "=")
    name=kv[1]
    val=kv[2]
    sub(/ \(default\)/, "", val)
    defaults[name]=val
    order[++n]=name
    next
  }
  /^[[:space:]]*-o [A-Za-z0-9_-]+=/ {
    line=$0
    sub(/^[[:space:]]*-o /, "", line)
    split(line, kv, "=")
    name=kv[1]
    val=kv[2]
    if (name in defaults && !(name in alt) && val != defaults[name] && name !~ /^(copies|media|orientation-requested|print-color-mode|print-quality|printer-resolution|output-bin|media-source)$/) {
      alt[name]=val
    }
  }
  END {
    for (i = 1; i <= n; i++) {
      name = order[i]
      if (name in alt) { print name, defaults[name], alt[name]; exit }
    }
  }
')
if [[ -z "${opt_name:-}" ]]; then
  echo "$options_output" >&2
  fail "could not find a Gutenprint vendor option with a non-default alternative value to test"
fi
echo "Testing vendor option: $opt_name (default=$opt_default, alternative=$opt_alt)"

print_with_sink() {
  local option_setting="$1" out_file="$2"
  python3 tests/socket-sink.py "$SINK_PORT" "$out_file" &
  SINK_PID=$!
  sleep 0.2
  if [[ -n "$option_setting" ]]; then
    podman exec "$NAME" gutenprint-printer-app \
      -u "$PRINTER_URI" -d "$PRINTER" -o "$option_setting" \
      /usr/share/gutenprint-printer-app/testpage.pdf submit >/dev/null
  else
    podman exec "$NAME" gutenprint-printer-app \
      -u "$PRINTER_URI" -d "$PRINTER" \
      /usr/share/gutenprint-printer-app/testpage.pdf submit >/dev/null
  fi
  local received=0
  for _ in $(seq 1 180); do
    [[ -s "$out_file" ]] && { received=1; break; }
    sleep 0.5
  done
  wait "$SINK_PID" 2>/dev/null || true
  SINK_PID=""
  [[ "$received" -eq 1 ]] || fail "no socket output captured for option setting '$option_setting'"
}

print_with_sink "" "$BASELINE_SINK"
print_with_sink "${opt_name}=${opt_alt}" "$CHANGED_SINK"

baseline_size="$(wc -c < "$BASELINE_SINK")"
changed_size="$(wc -c < "$CHANGED_SINK")"
echo "Baseline sink: ${baseline_size} bytes; changed sink: ${changed_size} bytes"

if cmp -s "$BASELINE_SINK" "$CHANGED_SINK"; then
  fail "changing $opt_name from '$opt_default' to '$opt_alt' produced byte-identical filter output -- option change did not reach the real driver/filter"
fi

echo "OK: expert driver '$DRIVER' exposes ${option_count} options; changing '$opt_name' altered the real filter output captured at the socket sink"
