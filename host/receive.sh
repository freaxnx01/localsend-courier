#!/usr/bin/env bash
# Headless LocalSend receive daemon. Saves incoming files into $INBOX.
# Wrapped in a loop so it keeps serving even if the CLI exits after a session;
# under systemd, Restart=always covers the same case.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${CONFIG_ENV:-$SCRIPT_DIR/config.env}"

mkdir -p "$INBOX"

args=(recv -d "$INBOX")
[ -n "${PIN:-}" ] && args+=(-p "$PIN")
[ "${HTTPS:-true}" = "false" ] && args+=(--https=false)
[ -n "${DEVICE_NAME:-}" ] && args+=(--name "$DEVICE_NAME")

echo "[receive] serving into $INBOX (https=${HTTPS:-true}, pin=$([ -n "${PIN:-}" ] && echo yes || echo no))"

while true; do
    "${LOCALSEND_CLI:-localsend-cli}" "${args[@]}" || echo "[receive] recv exited ($?); restarting in 2s" >&2
    sleep 2
done
