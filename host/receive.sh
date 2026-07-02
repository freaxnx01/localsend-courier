#!/usr/bin/env bash
# Headless LocalSend receive daemon. Saves incoming files into $INBOX.
# Wrapped in a loop so it keeps serving even if the CLI exits after a session;
# under systemd, Restart=always covers the same case.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${CONFIG_ENV:-$SCRIPT_DIR/config.env}"

mkdir -p "$INBOX"

# Flag grammar of aduggleby/localsend-cli (v0.9.x): global options (--alias,
# --protocol) come BEFORE the subcommand; subcommand options (--output, --pin)
# after it.
args=()
[ -n "${DEVICE_NAME:-}" ] && args+=(--alias "$DEVICE_NAME")
[ "${HTTPS:-true}" = "false" ] && args+=(--protocol http)
args+=(receive --output "$INBOX")
[ -n "${PIN:-}" ] && args+=(--pin "$PIN")
[ -n "${PORT:-}" ] && args+=(--port "$PORT")

echo "[receive] serving into $INBOX (https=${HTTPS:-true}, pin=$([ -n "${PIN:-}" ] && echo yes || echo no))"

while true; do
    "${LOCALSEND_CLI:-localsend-cli}" "${args[@]}" || echo "[receive] recv exited ($?); restarting in 2s" >&2
    sleep 2
done
