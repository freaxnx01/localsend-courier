#!/usr/bin/env bash
# Watch $INBOX for delete markers ("<name><MARKER_SUFFIX>") and remove the
# matching received file plus the marker itself. Requires inotify-tools.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${CONFIG_ENV:-$SCRIPT_DIR/config.env}"

mkdir -p "$INBOX"

if ! command -v inotifywait >/dev/null 2>&1; then
    echo "[delete-watcher] inotifywait not found. Install inotify-tools." >&2
    exit 1
fi

log() { echo "[delete-watcher] $*"; }

# Process one marker file name (basename only). Safely deletes the target
# strictly inside $INBOX.
process_marker() {
    local marker="$1"
    case "$marker" in
        *"$MARKER_SUFFIX") ;;
        *) return 0 ;;                       # not a marker
    esac

    local target="${marker%"$MARKER_SUFFIX"}"

    # Refuse anything that could escape the inbox.
    if [ -z "$target" ] || [[ "$target" == *"/"* ]] || [ "$target" = "." ] || [ "$target" = ".." ]; then
        log "ignoring suspicious marker: $marker"
        rm -f -- "$INBOX/$marker"
        return 0
    fi

    if [ -e "$INBOX/$target" ]; then
        rm -f -- "$INBOX/$target"
        log "deleted $target"
    else
        log "target not present (already gone): $target"
    fi
    rm -f -- "$INBOX/$marker"
}

# Startup sweep: handle markers that arrived while the watcher was down.
shopt -s nullglob
for m in "$INBOX"/*"$MARKER_SUFFIX"; do
    process_marker "$(basename "$m")"
done
shopt -u nullglob

log "watching $INBOX for *$MARKER_SUFFIX"
inotifywait -m -q -e close_write -e moved_to --format '%f' "$INBOX" | while read -r fname; do
    process_marker "$fname"
done
