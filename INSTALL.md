# INSTALL

Setting up screenpresso-localsend on a new pair of machines: a **Windows client**
(where Screenpresso runs) and a **Linux host** (where the captures should land).

Read [`PROJECT-OVERVIEW.md`](PROJECT-OVERVIEW.md) first if you want to know what
the tool does before installing it.

---

## 1. Prerequisites

### Both sides

| Requirement | Why |
|---|---|
| [`aduggleby/localsend-cli`](https://github.com/aduggleby/localsend-cli) **0.9.x** | Both halves shell out to it. **Not** the unrelated `localsend-cli` v0.0.7 (`send/recv/scan`, `--ip`) — that one cannot talk to a LocalSend receiver at all. |
| TCP reachability on the LocalSend port (default **53317**), client → host | The transport. |
| Agreement on marker suffix, port, transport and PIN | See *Configuration* below — these four must match or the two halves silently disagree. |

If the two machines are on **different subnets**, LocalSend's UDP discovery
cannot work. That is fine: the sender always addresses the host with
`--direct <host>:<port>`, which skips discovery entirely. Nothing needs to be
configured for this beyond setting `host` correctly.

### Windows client

| Requirement | Notes |
|---|---|
| **PowerShell 7+** (`pwsh`) | `Send-Screenpresso.ps1` declares `#requires -Version 7.0`. Windows PowerShell 5.1 is not enough. |
| **Screenpresso** | Or anything else that drops files into a folder — the sender does not talk to Screenpresso, it only watches its output folder. |
| An **interactive desktop session** | The clipboard features need one. A task run as a service or with `S4U` logon can send files but cannot write the clipboard. |

Check the capture folder before configuring. `[Environment]::GetFolderPath('MyPictures')`
is what the sender uses when `watchFolder` is empty, and on a OneDrive-redirected,
localised profile that is **not** `%USERPROFILE%\Pictures`:

```powershell
[Environment]::GetFolderPath('MyPictures')
# e.g. C:\Users\<you>\OneDrive - <tenant>\Bilder
```

### Linux host

| Requirement | Notes |
|---|---|
| A **LocalSend receiver** writing into one inbox folder | Either `host/receive.sh` from this repo, or one you already run (see *Coexisting* below). |
| **`inotify-tools`** | `delete-watcher.sh` needs `inotifywait`. `sudo apt install inotify-tools`. |
| **systemd user services** + linger | The units are `systemd --user` units; `loginctl enable-linger $USER` keeps them alive without a login session. |

---

## 2. Install the host

```bash
git clone https://github.com/freaxnx01/screenpresso-localsend.git
cd screenpresso-localsend/host
cp config.env.example config.env
$EDITOR config.env          # set INBOX, PORT, DEVICE_NAME, LOCALSEND_CLI, PIN
./install.sh
```

**Do not run `install.sh` under `sudo`.** It installs `systemd --user` units and
calls `loginctl enable-linger "$USER"` — under `sudo` it would target *root's*
user manager instead of yours.

It installs two units:

- `screenpresso-receiver.service` — the headless receive loop
- `screenpresso-delete-watcher.service` — applies the delete markers

Check both:

```bash
systemctl --user is-active screenpresso-receiver.service screenpresso-delete-watcher.service
journalctl --user -u screenpresso-delete-watcher.service -f
```

### Coexisting with a receiver you already run

If the host already runs a LocalSend receiver (a GUI instance, `localgo`, …) on
the port you want, **do not stand up a second one**. Install only the
delete-watcher and point it at the existing receiver's download folder:

1. Write `host/config.env` with `INBOX` set to that folder and `PORT` to the port the existing receiver listens on.
2. Render `screenpresso-delete-watcher.service` into `~/.config/systemd/user/` by hand, replacing `After=/Wants=screenpresso-receiver.service` with the existing receiver's unit name.
3. `systemctl --user enable --now screenpresso-delete-watcher.service` and `loginctl enable-linger "$USER"`.

`install.sh` is not used in this case — it installs both units unconditionally.

---

## 3. Install the Windows client

```powershell
git clone https://github.com/freaxnx01/screenpresso-localsend.git
cd screenpresso-localsend\sender
Copy-Item config.example.json config.json
```

Get the CLI — `Get-LocalSendCli.ps1` prints the releases URL or builds from
source with cargo; it does **not** download a binary for you:

```powershell
pwsh -NoProfile -File .\Get-LocalSendCli.ps1
```

Then edit `config.json` (see *Configuration*), and run the sender in the
foreground once to confirm it works:

```powershell
pwsh -NoProfile -File .\Send-Screenpresso.ps1
```

Make it permanent — a hidden per-user task that starts at logon:

```powershell
pwsh -NoProfile -File .\Install-Sender.ps1
Start-ScheduledTask -TaskName 'screenpresso-localsend'

# remove again:
pwsh -NoProfile -File .\Install-Sender.ps1 -Unregister
```

The task runs with `LogonType Interactive` on purpose. Do not "fix" the brief
console flash at logon by switching it to `S4U` — that removes the desktop
session the clipboard needs.

---

## 4. Configuration

### Client — `sender/config.json`

`config.json` is gitignored; `config.example.json` is the template.

```json
{
  "host": "10.0.0.5",
  "port": 53317,
  "https": true,
  "pin": "",
  "localSendCli": "C:/Users/you/AppData/Local/Programs/localsend-cli/localsend-cli.exe"
}
```

**Use forward slashes in paths.** JSON needs backslashes doubled, and a single
backslash is an easy, silent mistake.

Leave `watchFolder` empty unless the captures go somewhere other than
`<MyPictures>\Screenpresso`.

### Host — `host/config.env`

```bash
INBOX="$HOME/screenpresso-inbox"
MARKER_SUFFIX=".localsend-delete"
PIN=""
HTTPS="true"
DEVICE_NAME="screenpresso-host"
PORT=""
LOCALSEND_CLI="localsend-cli"
```

### The four settings that must match

| Setting | Client | Host |
|---|---|---|
| Marker suffix | `deleteMarkerSuffix` | `MARKER_SUFFIX` |
| Port | `port` | `PORT` |
| Transport | `https` | `HTTPS` |
| PIN | `pin` | `PIN` |

### Optional — clipboard-text hotkeys

Off by default. When enabled, the sender also registers global hotkeys that save
the clipboard's **text** to a file and put a path back on the clipboard. Because
the file is written into the watched folder, it syncs to the host and
delete-mirrors like a capture.

```json
"clipboardText": {
  "enabled": true,
  "folder": "",
  "minChars": 50,
  "hostInbox": "/home/admin/localsend-inbox",
  "hotkeyWindowsPath": "Ctrl+Shift+L",
  "hotkeyHostPath": "Ctrl+Shift+J",
  "hotkeyOpenFolder": "Ctrl+Shift+O"
}
```

- `folder` empty = the watched folder, which is what makes the dump sync.
- `hostInbox` is only used to build the path string for `hotkeyHostPath`; it is not verified against the host.
- `minChars` refuses accidental short clipboards.
- Add `.log` to `fileExtensions`, or the dumps are written but never sent.
- A hotkey already owned by another application is reported as a `WARN` at startup and stays inactive; the file sync is unaffected.

---

## 5. Verify the installation

Do these in order — each one isolates a different layer:

1. **CLI identity** — start the sender. It probes the binary at startup and refuses v0.0.7 with a pointer to `Get-LocalSendCli.ps1`.
2. **Send** — drop any file with a whitelisted extension into the watched folder. Expect `Sending new file: …` in the log and the file in the host's inbox within a few seconds.
3. **Clipboard** — paste. You should get the filename.
4. **Delete** — delete the file locally. Expect `Local delete detected: …` on the client and `[delete-watcher] deleted …` in the host's journal, with no `.localsend-delete` file left behind.
5. **Hotkeys**, if enabled — copy a long text, press `Ctrl+Shift+L`, and confirm both the notification and that the path is on your clipboard.

Client log: `%LOCALAPPDATA%\screenpresso-localsend\sender.log`
Host log: `journalctl --user -u screenpresso-delete-watcher.service`

---

## 6. Troubleshooting

| Symptom | Cause |
|---|---|
| `PreUpload Fingerprint mismatch`, `Invalid body`, or `scan` finds nothing | The wrong `localsend-cli` (v0.0.7 of an unrelated project). Get 0.9.x. |
| Nothing is sent, no errors | The extension isn't in `fileExtensions`, or the file never goes idle for `stabilizeSeconds`. |
| Files arrive, deletes don't | `MARKER_SUFFIX` differs from the client's `deleteMarkerSuffix`, or `inotify-tools` isn't installed. |
| Watcher active but markers pile up | The watcher is watching a different folder than the receiver writes to. |
| Clipboard never updates | The sender is running without an interactive desktop session (service or `S4U` task). |
| Hotkey does nothing | Another application owns it — the startup log says so. Pick a different combination. |
| Nothing at all is detected in the capture folder | The folder resolved differently than expected; print `[Environment]::GetFolderPath('MyPictures')` and set `watchFolder` explicitly. |
| A OneDrive "Files On-Demand" capture folder | Files written by an interactive app sync fine, but a non-interactive shell cannot create files there. Test with a real capture, not a scripted one. |
