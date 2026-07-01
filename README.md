# screenpresso-localsend

Auto-forward [Screenpresso](https://www.screenpresso.com/) screenshots to another
machine over [LocalSend](https://localsend.org/), copy the filename to your
clipboard, and mirror local deletions to the receiving host.

- **Sender** — Windows 11, PowerShell 7 (`pwsh`). Watches your Screenpresso
  capture folder and sends every new file to a configurable host/IP.
- **Host** — Linux box running a headless LocalSend receive daemon plus a small
  companion watcher that mirrors deletions.

## Why a companion watcher?

The LocalSend protocol is **send-only** — there is no official CLI (upstream
[issue #11](https://github.com/localsend/localsend/issues/11) is still open) and
no way to tell a peer *"delete file X"*. Both the sender and the daemon in this
project shell out to the third-party Go CLI
[`0w0mewo/localsend-cli`](https://github.com/0w0mewo/localsend-cli).

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

On **both** machines. With Go 1.21+ installed:

```sh
go install github.com/0w0mewo/localsend-cli@latest
```

The binary lands in `$(go env GOPATH)/bin` (`%USERPROFILE%\go\bin` on Windows).
Add that to `PATH`, or point `localSendCli` in the config at the full path.
Prebuilt binaries are also on the CLI's
[releases page](https://github.com/0w0mewo/localsend-cli/releases).

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
sudo ./install.sh           # installs + enables both systemd services
```

This starts:
- `screenpresso-receiver.service` — `localsend-cli recv -d $INBOX`
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
| `pin`                  | `""`                                      | LocalSend PIN, if the receiver requires one. |
| `https`                | `true`                                    | Use HTTPS transport (must match the receiver). |
| `watchFolder`          | `""` → `Pictures\Screenpresso`            | Folder to watch. Empty = Screenpresso default. |
| `fileExtensions`       | png, jpg, jpeg, gif, bmp, webp, mp4       | Only files with these extensions are sent. |
| `clipboard`            | `"name"`                                  | `name` = copy filename, `path` = full path, `none`. |
| `localSendCli`         | `"localsend-cli"`                         | Command or full path to the CLI. |
| `deleteMarkerSuffix`   | `".localsend-delete"`                     | Suffix for delete-marker files. Must match host. |
| `pollIntervalSeconds`  | `2`                                       | How often the folder is reconciled. |
| `stabilizeSeconds`     | `1.5`                                      | A file must be idle this long before it's sent (waits for writes/screencasts to finish). |
| `sendExistingOnStartup`| `false`                                   | If true, send files already present at first run. |
| `stateFile`            | `""` → `%LOCALAPPDATA%\...\state.json`     | Where the known-file state is stored. |
| `logFile`              | `""` → `%LOCALAPPDATA%\...\sender.log`     | Log file path. |

### Host — `host/config.env`

| Variable        | Default                         | Description |
|-----------------|---------------------------------|-------------|
| `INBOX`         | `$HOME/screenpresso-inbox`      | Where received files (and markers) land. |
| `MARKER_SUFFIX` | `.localsend-delete`             | Must match the sender's `deleteMarkerSuffix`. |
| `PIN`           | *(empty)*                       | PIN required from senders. |
| `HTTPS`         | `true`                          | Use HTTPS transport (must match the sender). |
| `DEVICE_NAME`   | `screenpresso-host`             | Name advertised on the network. |

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

## Security notes

- LocalSend traffic stays on your LAN. Set a `PIN` (and keep `https: true`) so
  random devices on the network can't push files to the daemon.
- The delete watcher only ever removes files **inside `INBOX`** and refuses
  marker names containing path separators, so a malicious marker can't escape the
  inbox.

## License

MIT — see [LICENSE](LICENSE).
