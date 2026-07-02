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
  Both sides shell out to the third-party Go CLI
  [`0w0mewo/localsend-cli`](https://github.com/0w0mewo/localsend-cli)
  (`send --ip/-f/-p/--https`, `recv -d <dir>`).
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

## Next step (the only blocker)
Publish under **freaxnx01**. `gh` on this machine is authenticated only as
`anim-bossinfo-ch`; there is no freaxnx01 token/`.envrc`. Once authenticated as
freaxnx01:

```bash
cd ~/repos/github/freaxnx01/public/screenpresso-localsend
gh repo create freaxnx01/screenpresso-localsend --public --source . --remote origin --push \
  --description "Auto-forward Screenpresso screenshots over LocalSend with clipboard + delete mirroring"
```

## Optional follow-ups
- Confirm the installed `localsend-cli`'s exact `recv`/`send` flags on the real
  Linux host against `host/config.env` and `receive.sh`.
- Consider adding a `--name` device flag check (used in `receive.sh`).
