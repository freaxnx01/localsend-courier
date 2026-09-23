# PROJECT-OVERVIEW — screenpresso-localsend

## Purpose

Forward every screenshot [Screenpresso](https://www.screenpresso.com/) takes on a
Windows workstation to a Linux host over
[LocalSend](https://localsend.org/), put the filename on the clipboard, and
mirror local deletions so the two sides don't drift apart.

## Core need

Captures are made on Windows but consumed on the Linux box (agents, scripts,
issue attachments, a knowledge-base vault). Copying them across by hand — and
remembering to clean up the copy after deleting the original — is the friction
this removes. The clipboard step exists so the capture can be *referenced by
name* in a doc, chat message or issue seconds after it was taken.

## Stakeholders

Single-author personal tooling (`freaxnx01`). Public repo, MIT — anyone with the
same Screenpresso + LocalSend setup can use it, but there is no support
commitment and no release cadence.

## Vision

Stay a thin pipe. Two scripts, one marker-file convention, no daemon of our own
beyond what systemd needs. Routing captures onward (vault, GitHub issue, repo,
bin) belongs to the separate `screenpresso-triage` skill, not here.

## Key features

- Watches the Screenpresso capture folder and sends each new file to a
  configured host via `localsend-cli`.
- Copies the filename (or full path, or nothing) to the Windows clipboard after
  a successful send.
- Mirrors local deletions to the host through a `<name>.localsend-delete`
  marker file that a host-side watcher acts on.
- Survives restarts: a JSON state file means deletions that happened while the
  sender was stopped are still reconciled on the next start.
- Coexists with an unrelated LocalSend receiver already running on the host.

## Architecture in one paragraph

`sender/Send-Screenpresso.ps1` (PowerShell 7) runs a poll loop that reconciles
the watch folder against a JSON state file in
`%LOCALAPPDATA%\screenpresso-localsend\`. A file that is new, matches the
extension whitelist and has been idle for `stabilizeSeconds` is handed to
`localsend-cli send --to <host> --direct <host:port> --file <path>`; on success
it is recorded in state and its name goes to the clipboard. A name that is in
state but no longer on disk is a deletion: the sender writes a temporary
`<name>.localsend-delete` file and sends it over the same transport. On the
host, `host/delete-watcher.sh` watches the inbox with `inotifywait` and, for
each marker, removes the matching file and the marker itself, refusing any
target containing `/`, `.` or `..`. LocalSend itself has no delete operation and
no official CLI, which is why deletion is ridden over the file transport and why
both halves shell out to the third-party
[`aduggleby/localsend-cli`](https://github.com/aduggleby/localsend-cli) (0.9.x).

## Use cases in scope

- Screenshot (or Screenpresso video — `.mp4` is in the whitelist) lands on the
  host within a few seconds of capture.
- The filename is on the clipboard, ready to paste as a reference.
- Deleting the local capture removes the host's copy.
- The sender is stopped and restarted without re-sending the whole folder or
  losing deletions that happened in between.
- The host already runs someone else's LocalSend receiver on port 53317.

## Use cases explicitly out of scope

- **Host → Windows.** The pipe is one-way by design.
- **Edits and renames.** State is keyed by filename; re-saving an annotated
  capture under the same name is *not* re-sent, and a rename reads as
  delete + new file.
- **Subfolders.** The folder scan is not recursive.
- **Name collisions.** A second file with a name already in the inbox
  overwrites it.
- **Authorization beyond an optional PIN.** Anything that can send into the
  inbox can also send a delete marker; the host guard stops path traversal, not
  a malicious marker naming a legitimate file.
- **Backup, history, retention.** The inbox is a landing zone, not an archive.

## The contract between the two halves

Both sides must agree on exactly four things — everything else is local detail:

| Setting | Sender (`sender/config.json`) | Host (`host/config.env`) |
|---|---|---|
| Marker suffix | `deleteMarkerSuffix` | `MARKER_SUFFIX` |
| Port | `port` | `PORT` |
| Transport | `https` | `HTTPS` |
| PIN | `pin` | `PIN` |

## Deployed topology

Windows sender → `srvdmsk8s01`. The host's receiver is a pre-existing
**localgo** instance on 53317 with `--auto-accept` writing to
`~/localsend-inbox`; only `screenpresso-delete-watcher.service` was installed
there, pointed at that inbox. The repo's own `host/receive.sh` +
`screenpresso-receiver.service` exist for a fresh host but are deliberately not
deployed. The two machines are on different subnets, so LocalSend discovery
cannot work and `--direct` is mandatory.

Current status, open items and the incident record live in
[`docs/STATUS.md`](docs/STATUS.md).
