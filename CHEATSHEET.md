# Cheat sheet

Everything you need day to day. Setup lives in [INSTALL.md](INSTALL.md).

## Keyboard shortcuts

Registered by the sender while it runs. Defaults — rebind in `sender/config.json`
under `clipboardText`.

| Shortcut | Does | Clipboard afterwards |
|---|---|---|
| `Ctrl+Shift+L` | Saves the clipboard's **text** to `clips\console-<stamp>.log` | Windows path, e.g. `C:\Users\…\clips\console-20260923-115549.log` |
| `Ctrl+Shift+J` | Same file | **Host** path, e.g. `/home/admin/localsend-inbox/console-20260923-115549.log` |
| `Ctrl+Shift+O` | Opens the dump folder in Explorer | unchanged |

Either save also **sends** the file to the host and mirrors a later local delete.

**Refused, with a notification and nothing written:** an empty or non-text
clipboard, and anything shorter than `minChars` (default 50).

**No screenshot shortcut here** — captures come from Screenpresso's own hotkeys;
this tool only watches the folder they land in.

## Paths

| What | Where |
|---|---|
| Captures watched | `<MyPictures>\Screenpresso` (OneDrive-redirected and localised on a managed profile) |
| Clipboard dumps | `%LOCALAPPDATA%\localsend-courier\clips` |
| Log | `%LOCALAPPDATA%\localsend-courier\sender.log` |
| State | `%LOCALAPPDATA%\localsend-courier\state.json` |
| Config | `sender\config.json` (gitignored) |
| Host inbox | `~/localsend-inbox` |

## Client commands

```powershell
# is it running?
Get-ScheduledTask -TaskName 'localsend-courier' | Get-ScheduledTaskInfo

Start-ScheduledTask -TaskName 'localsend-courier'
Stop-ScheduledTask  -TaskName 'localsend-courier'

# follow the log
Get-Content "$env:LOCALAPPDATA\localsend-courier\sender.log" -Tail 20 -Wait

# foreground run (Ctrl+C to stop) / one reconcile pass and exit
pwsh -NoProfile -File .\sender\Send-Screenpresso.ps1
pwsh -NoProfile -File .\sender\Send-Screenpresso.ps1 -Once

# install / remove the logon task
pwsh -NoProfile -File .\sender\Install-Sender.ps1
pwsh -NoProfile -File .\sender\Install-Sender.ps1 -Unregister
```

Config changes need a restart: `Stop-ScheduledTask` then `Start-ScheduledTask`.

## Host commands

```bash
systemctl --user is-active localsend-courier-delete-watcher.service
systemctl --user restart localsend-courier-delete-watcher.service
journalctl --user -u localsend-courier-delete-watcher.service -f

ls -la ~/localsend-inbox/

# delete one file by hand, the way the sender would
touch ~/localsend-inbox/<name>.localsend-delete
```

## Reading the log

| Line | Meaning |
|---|---|
| `hotkey      : Ctrl+Shift+L - …` | Registered at startup. A `WARN` here means another app owns it. |
| `Sending new file: X` | Picked up and being sent. |
| `Clipboard <- X` | Filename copied after a successful send. |
| `Clipboard text -> X; clipboard <- …` | A hotkey save. No `Clipboard <- X` follows — the path is left alone on purpose. |
| `Local delete detected: X` | Marker sent; the host deletes its copy. |
| `watch folder : A \| B` | Both watched folders — captures and dumps. |

## Quick checks

```powershell
# where does the tool think your captures are?
[Environment]::GetFolderPath('MyPictures')

# is the CLI the right one? (needs 0.9.x with --to/--direct)
& "$env:LOCALAPPDATA\Programs\localsend-cli-aduggleby\localsend-cli.exe" --version
```

| Symptom | First thing to check |
|---|---|
| Hotkey does nothing at all | Sender running? Startup log says `WARN` for that key? |
| Hotkey fires, no file | The dump folder must be writable — a OneDrive Files On-Demand folder is not. |
| File sent, clipboard wrong | Another app wrote the clipboard after; or `clipboard` is set to `path`/`none`. |
| Nothing sent | Extension missing from `fileExtensions`, or the file is still being written. |
| Deletes don't mirror | `deleteMarkerSuffix` ≠ host `MARKER_SUFFIX`, or the watcher is down. |
