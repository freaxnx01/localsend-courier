# screenpresso-localsend — Status & Handoff

**Repo:** https://github.com/freaxnx01/screenpresso-localsend (public)
**Local:** `~/repos/github/freaxnx01/public/screenpresso-localsend`
**Branch:** `main` — in sync with `origin/main`.
**Date:** 2026-09-21 (host bring-up completed)

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
- `host/receive.sh` — headless `receive --output $INBOX` loop (aduggleby grammar).
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

## Host bring-up — DONE (2026-09-21, `srvdmsk8s01`)

The host side is live. Resolution of the old port conflict: **option (b)** — we do
*not* run our own receiver. The box already runs **localgo** (`bethropolis/localgo`,
LocalSend v2.1) as a lingering *user* service on `53317` with `--auto-accept`,
downloading into `/home/admin/localsend-inbox`. Standing up a second receiver on a
second port would have duplicated a working service for no gain, so only the
delete-watcher was installed, pointed at localgo's inbox.

- `inotify-tools` 4.23.9.0 installed (`apt`).
- `host/config.env` written on the host: `INBOX=/home/admin/localsend-inbox`,
  `PORT=53317`, `DEVICE_NAME=CC-CLI`, `LOCALSEND_CLI=/home/admin/.local/bin/localsend-cli`.
- `screenpresso-delete-watcher.service` rendered by hand into
  `~/.config/systemd/user/` (`After=/Wants=localgo.service` instead of
  `screenpresso-receiver.service`), enabled + started, linger on. `install.sh` was
  **not** used — it installs both units unconditionally.
- `screenpresso-receiver.service` is deliberately **not** installed.

### Verified live on the host
- Marker round-trip over the wire: `localsend-cli send --to CC-CLI --direct
  127.0.0.1:53317 --file pair-test.png` → lands in the inbox → sending
  `pair-test.png.localsend-delete` the same way → watcher removes **both**.
- Path-traversal guard: a marker named `..%2Ftraversal-sentinel.txt.localsend-delete`
  was treated as a literal filename; the sentinel outside the inbox survived and the
  marker was cleaned up.
- The sender script's exact flag grammar (`send --to <name> --direct <host:port>
  --file <path>`) is confirmed correct against **aduggleby/localsend-cli 0.9.2**
  talking to localgo.

## Open items

0. **BLOCKER — cannot push.** This STATUS commit is made locally but **not on
   GitHub**. Both the Windows dev box and `srvdmsk8s01` authenticate as
   `anim-bossinfo-ch`, which has only `pull` on `freaxnx01/screenpresso-localsend`
   (`gh api repos/freaxnx01/screenpresso-localsend --jq .permissions` →
   `push: false`). The commit exists on `main` in **both** working copies, one
   ahead of `origin/main` (`e32c284`). Fix by switching `gh` to the `freaxnx01`
   account or granting `anim-bossinfo-ch` write, then `git push origin main` from
   either box.
1. **Windows sender is not installed anywhere we can see.** The dev box
   (`C--Develop-GitHubRepos-...`) has **no Screenpresso** and **no scheduled task**,
   so the screenshot→send leg could not be exercised from there. Whichever machine
   produced `2026-07-03_15h42_35.png` in the inbox is the real sender host; the
   sender still needs installing/verifying on it.
2. **DONE (2026-09-22, commit `29e1e8a`).** ~~CLI confusion on the dev box.~~ `%LOCALAPPDATA%\Programs\localsend-cli\localsend.exe`
   is **v0.0.7 of a different project** (`send/recv/scan`, `--ip`), not
   aduggleby/localsend-cli 0.9.x (`--protocol`, `send --to --direct --file`) which
   `Send-Screenpresso.ps1` targets. It cannot talk to localgo at all — `PreUpload
   Fingerprint mismatch` over https, `Invalid body` over http, and `scan` finds
   nothing (different subnet). `Assert-Cli` now probes the binary once at startup
   and throws with a pointer to `Get-LocalSendCli.ps1`; accepts the grammar
   (`--to`/`--direct`) or a parsed version >= 0.9. Verified live against the real
   v0.0.7 binary. The dev box still has the wrong binary installed — replacing it
   only matters on the actual sender machine (item 1).
3. **DONE (2026-09-22, commit `4a6c5bd`).** README now has a "Running alongside an
   existing LocalSend receiver" section describing the deployed topology.
4. **Optional:** poll-based fallback in `delete-watcher.sh` to drop the
   inotify-tools dependency.
5. **NEW — found 2026-09-22, not acted on.** README Quick start step 3 says
   `sudo ./install.sh`, but `install.sh` is a `systemd --user` installer
   (`systemctl --user`, `loginctl enable-linger "$USER"`). Under `sudo` it would
   target **root's** user manager, not the invoking user's. The `sudo` should
   almost certainly be dropped. One-line fix, deliberately left for a decision.
