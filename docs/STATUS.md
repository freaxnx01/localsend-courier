# screenpresso-localsend — Status & Handoff

**Repo (local):** `~/repos/github/freaxnx01/public/screenpresso-localsend`
**Branch:** `main` — committed (1 commit, 13 files). **Not yet pushed to GitHub.**
**Date:** 2026-07-01

## Goal
A tool for Win11 (pwsh) that watches the Screenpresso capture folder
(`Pictures\Screenpresso`), sends each new file over LocalSend to a configurable
host/IP, copies the filename to the clipboard, and mirrors local deletions to
the host. New **public** GitHub repo under **freaxnx01**.

## Decisions made
- **LocalSend is send-only** — no official CLI, no remote-delete in the protocol.
  Both sides shell out to the third-party CLI
  [`aduggleby/localsend-cli`](https://github.com/aduggleby/localsend-cli)
  (Rust, v0.9.2, verified on the host). Grammar: globals `--alias/--protocol`
  BEFORE the subcommand; `receive --output <dir> [--pin]`;
  `send --to <label> --direct <host:port> --file <f> [--pin]`.
  (Originally written against `0w0mewo/localsend-cli` with `recv -d` /
  `send --ip/-f`; corrected 2026-07-02 to match the CLI actually deployed.)
- **Remote delete** ridden over the same transport: on local delete the sender
  transmits a `<name>.localsend-delete` marker file; a Linux companion watcher
  deletes the matching received file. (User chose "host companion watcher".)
- **Host receiver** = headless LocalSend daemon on **Linux** (user's choice), not
  the GUI. systemd `--user` services provided.
- Sender uses a **poll loop + JSON state file** (not just FileSystemWatcher) so
  deletions while stopped are still reconciled on restart.

## What's done (all committed)
- `sender/Send-Screenpresso.ps1` — watcher/sender (send + clipboard + delete markers).
- `sender/Install-Sender.ps1` — hidden per-user scheduled task at logon (+ `-Unregister`).
- `sender/Get-LocalSendCli.ps1`, `sender/config.example.json`.
- `host/receive.sh` — headless `recv -d $INBOX` loop.
- `host/delete-watcher.sh` — inotify watcher, applies markers, path-traversal guard.
- `host/install.sh` + two systemd unit files + `config.env.example`.
- `README.md`, MIT `LICENSE`, `.gitignore` (excludes real `config.json`/`config.env`).

## Verified
- Sender end-to-end with a stubbed CLI: new file → correct `send` args + clipboard
  set; delete → correct marker `send`; state cleaned up. ✓
- Watcher: deletes real file + marker, refuses a `..` traversal marker, leaves
  files outside the inbox untouched. ✓
- All 3 PowerShell scripts parse clean; all 3 bash scripts pass `bash -n`. ✓

## Verified against the real CLI (2026-07-02)
- On `srvdmsk8s01`: `localsend-cli` = **aduggleby/localsend-cli v0.9.2** at
  `~/.local/bin/localsend-cli`; an existing `localsend-receiver.service` already
  uses it. End-to-end loopback test passed with the corrected flags
  (`send --to <label> --direct <ip:port> --file` → `receive --output`); the file
  landed in the inbox under its basename (what the delete-watcher expects).
- **`inotify-tools` is NOT installed** on the host — the delete-watcher needs
  `inotifywait`. Install with `sudo apt install inotify-tools` before enabling
  `screenpresso-delete-watcher.service`.

## Next step
Repo is published at https://github.com/freaxnx01/screenpresso-localsend.
Remaining host-side action: `sudo apt install inotify-tools` on the target box.
