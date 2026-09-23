# screenpresso-localsend

Auto-forward [Screenpresso](https://www.screenpresso.com/) screenshots to another
machine over [LocalSend](https://localsend.org/), copy the filename to your
clipboard, and mirror local deletions to the receiving host.

- **Sender** — Windows 11, PowerShell 7 (`pwsh`). Watches your Screenpresso
  capture folder and sends every new file to a configurable host/IP.
- **Host** — Linux box running a headless LocalSend receive daemon plus a small
  companion watcher that mirrors deletions.

Setting this up on new machines: **[INSTALL.md](INSTALL.md)** — prerequisites per
side, install, configuration, verification and troubleshooting. Day-to-day
shortcuts, paths and commands: **[CHEATSHEET.md](CHEATSHEET.md)**. What the tool
is for and what it deliberately does not do:
[PROJECT-OVERVIEW.md](PROJECT-OVERVIEW.md).

## Why a companion watcher?

The LocalSend protocol is **send-only** — there is no official CLI (upstream
[issue #11](https://github.com/localsend/localsend/issues/11) is still open) and
no way to tell a peer *"delete file X"*. Both the sender and the daemon in this
project shell out to the third-party CLI
[`aduggleby/localsend-cli`](https://github.com/aduggleby/localsend-cli) — a Rust
tool built for non-interactive automation (verified against v0.9.2).

To get delete-on-host we ride the same transport: when you delete a screenshot
locally, the sender transmits a tiny **delete marker** file named
`<original-name>.localsend-delete`. The Linux companion watcher sees that marker
land in the inbox, deletes the matching real file, then removes the marker. No
extra ports, no extra protocol — everything flows through LocalSend.

```
Screenpresso  ──new file──►  Send-Screenpresso.ps1  ──localsend──►  recv daemon  ──►  inbox/
   folder      ──deleted──►   (sends delete marker)  ──localsend──►  recv daemon  ──►  inbox/name.localsend-delete
                                                                                          │
                                                                        delete-watcher.sh ┘  rm inbox/name (+ marker)
```

## Requirements

**Sender (Windows 11)**
- PowerShell 7+ (`pwsh`)
- `localsend-cli.exe` on `PATH` (see [Install the CLI](#install-the-localsend-cli))
- Screenpresso (any edition that saves to a folder)

**Host (Linux)**
- `localsend-cli` on `PATH`
- `inotify-tools` (`inotifywait`) for the delete watcher
- `systemd` (optional, for the provided service units)

## Quick start

### 1. Install the LocalSend CLI

On **both** machines. Download a prebuilt binary from the CLI's
[releases page](https://github.com/aduggleby/localsend-cli/releases), or build
from source with `cargo install --git https://github.com/aduggleby/localsend-cli localsend-cli`.

Put `localsend-cli` on `PATH`, or point `localSendCli` (sender) / `LOCALSEND_CLI`
(host) at the full path. On Windows, `sender/Get-LocalSendCli.ps1` automates this.

### 2. Configure the sender (Windows)

```powershell
cd sender
Copy-Item config.example.json config.json
notepad config.json   # set "host" to your Linux box's IP
```

Run it in the foreground to test:

```powershell
pwsh -NoProfile -File .\Send-Screenpresso.ps1 -ConfigPath .\config.json
```

Take a screenshot with Screenpresso — it should transfer to the host and the
filename should be on your clipboard. Delete it locally and the copy on the host
disappears too.

Install it as a hidden per-user scheduled task that starts at logon:

```powershell
pwsh -NoProfile -File .\Install-Sender.ps1 -ConfigPath .\config.json
# remove with:  pwsh -NoProfile -File .\Install-Sender.ps1 -Unregister
```

### 3. Configure the host (Linux)

```sh
cd host
cp config.env.example config.env
$EDITOR config.env          # set INBOX, PIN, HTTPS to match the sender
./install.sh                # installs + enables both systemd --user services
```

This starts:
- `screenpresso-receiver.service` — `localsend-cli [--alias NAME] [--protocol http] receive --output $INBOX`
- `screenpresso-delete-watcher.service` — mirrors deletions in `$INBOX`

Without systemd you can run the two scripts directly:

```sh
./receive.sh          # foreground receive daemon
./delete-watcher.sh   # foreground delete mirror
```

## Configuration

### Sender — `sender/config.json`

| Key                    | Default                                   | Description |
|------------------------|-------------------------------------------|-------------|
| `host`                 | *(required)*                              | Target IP or hostname of the Linux box. |
| `port`                 | `53317`                                   | LocalSend port on the host (sent via `--direct host:port`). |
| `pin`                  | `""`                                      | LocalSend PIN, if the receiver requires one. |
| `https`                | `true`                                    | Use HTTPS transport (must match the receiver). |
| `watchFolder`          | `""` → `Pictures\Screenpresso`            | Folder to watch. Empty = Screenpresso default. |
| `fileExtensions`       | png, jpg, jpeg, gif, bmp, webp, mp4, log  | Only files with these extensions are sent. |
| `clipboard`            | `"name"`                                  | `name` = copy filename, `path` = full path, `none`. |
| `localSendCli`         | `"localsend-cli"`                         | Command or full path to the CLI. |
| `deleteMarkerSuffix`   | `".localsend-delete"`                     | Suffix for delete-marker files. Must match host. |
| `pollIntervalSeconds`  | `2`                                       | How often the folder is reconciled. |
| `stabilizeSeconds`     | `1.5`                                      | A file must be idle this long before it's sent (waits for writes/screencasts to finish). |
| `sendExistingOnStartup`| `false`                                   | If true, send files already present at first run. |
| `stateFile`            | `""` → `%LOCALAPPDATA%\...\state.json`     | Where the known-file state is stored. |
| `logFile`              | `""` → `%LOCALAPPDATA%\...\sender.log`     | Log file path. |
| `clipboardText`        | *(disabled)*                              | Clipboard-text hotkeys — see below. |

### Host — `host/config.env`

| Variable        | Default                         | Description |
|-----------------|---------------------------------|-------------|
| `INBOX`         | `$HOME/screenpresso-inbox`      | Where received files (and markers) land. |
| `MARKER_SUFFIX` | `.localsend-delete`             | Must match the sender's `deleteMarkerSuffix`. |
| `PIN`           | *(empty)*                       | PIN required from senders. |
| `HTTPS`         | `true`                          | Use HTTPS transport (must match the sender). |
| `DEVICE_NAME`   | `screenpresso-host`             | Name advertised on the network (maps to `--alias`). |
| `PORT`          | *(empty → 53317)*               | Port to bind. Must match the sender's `port`. |

## Running alongside an existing LocalSend receiver

If the Linux box already runs a LocalSend receiver — e.g.
[`bethropolis/localgo`](https://github.com/bethropolis/localgo) as a
`systemd --user` service — there is no reason to start a second one. Skip
`screenpresso-receiver.service` entirely and install **only the delete
watcher**, pointed at the receiver you already have.

Point `host/config.env` at the existing receiver's settings instead of your own:

```sh
INBOX=/home/admin/localsend-inbox   # the receiver's download directory
MARKER_SUFFIX=".localsend-delete"   # must match the sender's deleteMarkerSuffix
DEVICE_NAME="CC-CLI"                # must match the receiver's advertised alias
PORT="53317"
HTTPS="true"
```

Two values have to line up or nothing arrives:

- `DEVICE_NAME` — the alias the existing receiver advertises (for localgo,
  `LOCALSEND_ALIAS` in `~/.config/localgo/localgo.env`). The sender addresses
  the host by that alias: `localsend-cli send --to CC-CLI --direct <host>:53317 …`.
- `MARKER_SUFFIX` — must match the sender's `deleteMarkerSuffix` (see
  [Configuration](#configuration)); otherwise markers just pile up in the inbox.

`install.sh` installs **both** units unconditionally, so don't run it here —
write the watcher unit yourself and order it after the receiver you actually
have:

```ini
# ~/.config/systemd/user/screenpresso-delete-watcher.service
[Unit]
Description=screenpresso-localsend delete-marker watcher
After=localgo.service
Wants=localgo.service

[Service]
Type=simple
Environment=CONFIG_ENV=%h/screenpresso-localsend/host/config.env
ExecStart=%h/screenpresso-localsend/host/delete-watcher.sh
Restart=always
RestartSec=2

[Install]
WantedBy=default.target
```

```sh
systemctl --user daemon-reload
systemctl --user enable --now screenpresso-delete-watcher.service
loginctl enable-linger "$USER"   # keep it running without an active login
```

To verify, send a file and then its marker from the sender machine:

```sh
localsend-cli send --to CC-CLI --direct <host>:53317 --file shot.png
localsend-cli send --to CC-CLI --direct <host>:53317 --file shot.png.localsend-delete
```

The first lands in `$INBOX`; the second makes the watcher remove both.

## How the sender works

A poll loop (default every 2 s) reconciles the watch folder against a small JSON
state file:

- **New file, idle for `stabilizeSeconds`** → send via `localsend-cli send`,
  record it in state, copy the name to the clipboard.
- **File in state that no longer exists on disk** → send a
  `<name>.localsend-delete` marker, then drop it from state.

Polling (rather than only a `FileSystemWatcher`) means deletions that happen
while the sender is stopped are still reconciled on the next start. Send failures
are logged and retried on the next poll — nothing is marked done until the CLI
returns success.

## Clipboard-text hotkeys

Optional, **off by default**. When `clipboardText.enabled` is true the sender also
registers global hotkeys that write the clipboard's *text* into a file and put a
path back on the clipboard:

| Hotkey | Default | Effect |
|---|---|---|
| Save, Windows path back | `Ctrl+Shift+L` | Writes `console-<stamp>.log`, clipboard gets the local path. |
| Save, host path back    | `Ctrl+Shift+J` | Same file, clipboard gets `<hostInbox>/<name>` — the path it will have on the host. |
| Open the folder         | `Ctrl+Shift+O` | Opens the folder in Explorer. |

Dumps are written to their own folder (`%LOCALAPPDATA%\screenpresso-localsend\clips`
by default), which the sender watches **in addition to** the capture folder — so a
console dump is sent and delete-mirrored exactly like a screenshot. Add `.log` to
`fileExtensions` or it will be written but never sent.

They deliberately do *not* go into the capture folder: a OneDrive **Files
On-Demand** folder accepts writes from the capturing application but rejects file
creation by other processes — every create fails with `Could not find file`. Point
`folder` at the capture folder only if you know it is a plain local directory.

Details worth knowing:

- Empty, non-text and shorter-than-`minChars` clipboards are refused with a notification; nothing is written and the clipboard is left alone.
- Files are UTF-8 **without** a BOM. Two saves in the same second get `-2`, `-3` … appended rather than overwriting each other.
- The sender does **not** overwrite the path with the file name when it then sends that file — hotkey-written files are exempt from the `clipboard` setting.
- A hotkey already owned by another application is logged as a `WARN` at startup and left inactive; file syncing is unaffected.
- This is the only part of the tool that *reads* the clipboard. Everything else only writes it.

Implementation: PowerShell has no global hotkeys, so a small C# type owns a hidden
message window, the `RegisterHotKey` registrations and the save/clipboard/notify
work, on its own STA thread (`pwsh` is MTA; the clipboard API requires STA). The
poll loop is untouched.

## Security notes

- LocalSend traffic stays on your LAN. Set a `PIN` (and keep `https: true`) so
  random devices on the network can't push files to the daemon.
- The delete watcher only ever removes files **inside `INBOX`** and refuses
  marker names containing path separators, so a malicious marker can't escape the
  inbox.

## License

MIT — see [LICENSE](LICENSE).
