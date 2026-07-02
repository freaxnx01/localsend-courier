#!/usr/bin/env bash
# Install the screenpresso-localsend host side as systemd --user services.
#
#   ./install.sh            install + enable + start both services
#   ./install.sh --uninstall   stop, disable and remove them
#
# User services keep running without an active login once linger is enabled
# (this script does that for you).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
RECV_UNIT="screenpresso-receiver.service"
WATCH_UNIT="screenpresso-delete-watcher.service"

uninstall() {
    systemctl --user disable --now "$RECV_UNIT" "$WATCH_UNIT" 2>/dev/null || true
    rm -f "$UNIT_DIR/$RECV_UNIT" "$UNIT_DIR/$WATCH_UNIT"
    systemctl --user daemon-reload
    echo "Removed services. (Received files in your INBOX are left untouched.)"
    exit 0
}

[ "${1:-}" = "--uninstall" ] && uninstall

# --- Preconditions ---
command -v systemctl >/dev/null 2>&1 || { echo "systemd (systemctl) is required." >&2; exit 1; }
command -v "${LOCALSEND_CLI:-localsend-cli}" >/dev/null 2>&1 || \
    echo "WARNING: localsend-cli not on PATH. Install aduggleby/localsend-cli (prebuilt binaries at https://github.com/aduggleby/localsend-cli/releases) and put it on PATH, or set LOCALSEND_CLI to its full path." >&2
command -v inotifywait >/dev/null 2>&1 || \
    echo "WARNING: inotifywait not found. Install inotify-tools (e.g. apt install inotify-tools)." >&2

# --- Config ---
if [ ! -f "$SCRIPT_DIR/config.env" ]; then
    cp "$SCRIPT_DIR/config.env.example" "$SCRIPT_DIR/config.env"
    echo "Created $SCRIPT_DIR/config.env from the example - review it before relying on it."
fi

chmod +x "$SCRIPT_DIR/receive.sh" "$SCRIPT_DIR/delete-watcher.sh"
mkdir -p "$UNIT_DIR"

render_unit() {
    local name="$1" desc="$2" exec="$3" after="$4"
    cat > "$UNIT_DIR/$name" <<EOF
[Unit]
Description=$desc
$after

[Service]
Type=simple
Environment=CONFIG_ENV=$SCRIPT_DIR/config.env
ExecStart=$SCRIPT_DIR/$exec
Restart=always
RestartSec=2

[Install]
WantedBy=default.target
EOF
}

render_unit "$RECV_UNIT" "screenpresso-localsend receive daemon" "receive.sh" \
    $'After=network-online.target\nWants=network-online.target'
render_unit "$WATCH_UNIT" "screenpresso-localsend delete-marker watcher" "delete-watcher.sh" \
    "After=$RECV_UNIT"

# Allow user services to run without an active session.
loginctl enable-linger "$USER" 2>/dev/null || \
    echo "NOTE: could not enable linger; services may stop when you log out."

systemctl --user daemon-reload
systemctl --user enable --now "$RECV_UNIT" "$WATCH_UNIT"

echo
echo "Installed and started:"
systemctl --user --no-pager status "$RECV_UNIT" "$WATCH_UNIT" | grep -E 'Loaded|Active' || true
echo
echo "Logs:  journalctl --user -u $RECV_UNIT -u $WATCH_UNIT -f"
