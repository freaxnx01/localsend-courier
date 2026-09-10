# agent-drop — design spec

**Status:** DRAFT — **awaiting user approval.** Three open items in §11 must be
answered before this becomes final. No code has been written.
**Date:** 2026-09-10
**Phase:** brainstorming (architectural path) → next is user approval, then `superpowers:writing-plans`.
**Target repo:** new public repo **`freaxnx01/agent-drop`** (does not exist yet).
This spec is parked in `screenpresso-localsend` only because the new repo has not
been created; **move it to `agent-drop` when that repo is created.**

## 1. Problem

When developing on the agent-dev server (Debian) and holding a file or screenshot
locally on Win11, sharing it with the AI agent on agent-dev is currently a
**manual LocalSend send**. Automate that. Same requirement at work and at home.

Three source cases, all the same pipeline:

- **Deliberate drops** — a file the user picks to share.
- **Screenshots** — Screenpresso captures.
- **AHK text dumps** — existing AutoHotkey tooling writes logs/long texts to files
  so the agent gets a *path* instead of a context-cluttering paste.

Optional extras requested: **delete on source after successful transfer**, and
**LLM-vision naming** of screenshots from their content before transfer.

## 2. Scope

**In scope:** an automated Win11 → agent-dev drop pipeline with configurable
multiple watch folders, optional delete-on-source, and optional LLM naming,
working at work and at home. Everything else found along the way is written down,
not acted on.

**Explicit boundary:** AHK's job ends when the file lands in a watched folder;
the tool's job starts there. Clipboard/hotkey capture stays in AHK, so this tool
never grows a Windows-hotkey dependency.

## 3. Decisions (all user-approved unless noted)

| # | Decision | Rationale |
|---|---|---|
| D1 | **Transport = SSH/`scp`** (not LocalSend) | No daemon, no PIN, no receiver service. Gives a **return channel**, which LocalSend (send-only) cannot: the remote side can rename and report the final path back. |
| D2 | **Trigger = watched drop folders**, multiple, configurable | Selective by construction — only deliberately dropped files go — yet fully automatic. User explicitly required *multiple* folders so the Screenpresso folder can also be a source. |
| D3 | **Naming = `claude -p` on agent-dev** | User has no Anthropic API key at work or home, and poor hardware for a local vision model. Headless Claude Code uses the existing subscription, no key to procure. |
| D4 | **New repo `freaxnx01/agent-drop`**, borrowing two patterns | Only the poll-loop + JSON state file and the scheduled-task installer carry over from `screenpresso-localsend`. Delete markers, receiver daemon, PIN and `localsend-cli` are all gone, and the old name no longer describes the tool. |
| D5 | **Orchestration = thin sender + one remote ingest script** | One ssh round trip; naming, rename, collision handling and the returned path all live in one testable bash script on agent-dev. Windows stays a dumb watch-and-push loop. |
| D6 | *[my call — overrulable]* `afterTransfer` defaults to **`archive`** (local `.sent/`), `delete` is per-folder opt-in | User said delete "should be an option", not the default. |
| D7 | *[my call — overrulable]* **Single-phase clipboard** — it receives the final path after ingest returns | Two-phase risks pasting the stale pre-rename path, defeating the feature. Cheap now that naming measured 6.4s, not 37s. |

### Rejected alternatives (do not re-litigate without new evidence)

- **LocalSend transport** — send-only, so no return channel; naming would have to
  run on Windows, needing an API key on the work laptop.
- **Local Ollama vision model** — user has inadequate hardware.
- **Anthropic API** — no key at work or home.
- **Windows-side naming** — measured **~37s** vs 6.4s on agent-dev, ties up the
  laptop's Claude session, and produced a worse name.
- **Systemd inbox processor on agent-dev** — breaks the return channel; Windows
  would have to poll for the final name (extra machinery, race-prone).
- **Thick Windows sender** — three ssh round trips, and naming/rename logic
  stranded in PowerShell where it is hardest to test.
- **Extending `screenpresso-localsend`** — two transports plus mutually exclusive
  delete semantics in one sender.

## 4. Verified facts (measured this session — trust these over intuition)

**agent-dev = `srvdmsk8s01`** (user-confirmed; 10.240.10.83, user `admin`).

- `claude` **is installed**: `/home/admin/.local/bin/claude`, 2.1.267, node
  v24.18.1 via nvm, `~/.claude` present (authenticated).
- Naming benchmark on agent-dev: **image 6.4s**, **text 12.1s**.
  Comparison: WSL2 12.2s/12.3s; Windows `claude.exe` ~37s.
- Naming quality, synthetic SSMS error screenshot →
  `ssms-error-4060-database-login-failed`. Synthetic DocMmt log →
  `docmmt-stamp-import-file-not-found`. Both good enough to ship.
- Windows→agent-dev `scp` verified end-to-end, **md5 matched both ends**.

### Gotcha 1 — non-interactive `PATH`

Non-interactive SSH gives only `/usr/local/bin:/usr/bin:/bin:/usr/games`;
`claude` is in `~/.local/bin`. This produced a **false negative** earlier in the
session ("claude NOT installed") which nearly sent the design down the wrong
path. The ingest script MUST export `PATH="$HOME/.local/bin:$PATH"` and call
`claude` by absolute path. Same bug class as the self-hosted-runner PATH reset.

Also: the interactive shell has an alias `claude='… --permission-mode auto'`.
Aliases do not apply non-interactively — pass `--allowedTools Read` explicitly.

### Gotcha 2 — `claude -p` needs stdin redirected

Without it, `Warning: no stdin data received in 3s…` is printed **to stdout** and
would be parsed as the filename. With `< /dev/null` the output is a clean single
line. Always redirect, and parse only the last non-empty line.

### Gotcha 3 — Windows `~/.ssh/config` has broken ACLs

Native OpenSSH (`C:\Windows\System32\OpenSSH\{ssh,scp}.exe`) exists and works,
but reading the user config fails with exit 255 (`Bad owner or permissions`) —
the file carries ACEs for both local `BOSS-5CG346117Q\aimboden` and the Entra
`BOSSINFO\aimboden` the session runs as. Likely why the `ssh.bat`→WSL2 shim exists.

**Do not repair ACLs.** Bypass the config entirely:

```powershell
$key = "$env:USERPROFILE\.ssh\id_ed25519"
$o = @('-F','NUL','-i',$key,'-o','BatchMode=yes','-o','ConnectTimeout=8')
& scp @o .\file.png 'admin@srvdmsk8s01:/tmp/'   # verified exit 0
```

Needs no machine change and does not depend on the user's ssh-config state.

## 5. Components — repo layout

```
sender/Watch-AgentDrop.ps1     # Win11 poll loop over N folders + JSON state
sender/Install-Sender.ps1      # hidden per-user scheduled task at logon (+ -Unregister)
sender/config.example.json     # multi-folder config (§6)
host/agent-drop-ingest         # THE script: naming, sanitize, collision, rename, echo path
host/install.sh                # copies ingest into ~/.local/bin. No daemon, nothing listening.
README.md, LICENSE (MIT), .gitignore
```

Remote footprint is **one script**. No systemd unit, no open port.

## 6. Config shape

```json
{
  "sshTarget": "admin@srvdmsk8s01",
  "sshKey": "%USERPROFILE%\\.ssh\\id_ed25519",
  "remoteStaging": "~/.agent-drop/staging",
  "stabilizeSeconds": 1.5,
  "pollIntervalSeconds": 2,
  "folders": [
    { "path": "%USERPROFILE%\\agent-drop",
      "remoteDir": "~/agent-inbox",
      "extensions": [],
      "naming": true,
      "namingExtensions": [".png",".jpg",".jpeg",".webp",".txt",".log",".md"],
      "afterTransfer": "archive",
      "clipboard": "remote-path" },

    { "path": "%USERPROFILE%\\OneDrive - bossinfo.ch AG\\Bilder\\Screenpresso",
      "remoteDir": "~/agent-inbox/shots",
      "extensions": [".png",".jpg",".mp4"],
      "naming": false,
      "afterTransfer": "keep",
      "clipboard": "none" },

    { "path": "%USERPROFILE%\\agent-drop-logs",
      "remoteDir": "~/agent-inbox/logs",
      "extensions": [".txt",".log"],
      "naming": true,
      "afterTransfer": "archive",
      "clipboard": "remote-path" }
  ]
}
```

Per-folder policy is the point: the capture archive keeps its files and skips the
naming latency; the deliberate drop folder gets named and archived.

Work and home are separate Windows machines, so each simply has its own
`config.json` — no profile switching. (Screenpresso path above is the real one
observed this session, under OneDrive.)

## 7. Data flow — the ordering is load-bearing

1. Poll detects a new file; it must be idle `stabilizeSeconds` (writes/screencasts finished).
2. `scp` → `remoteStaging/<original-name>`.
3. **One** `ssh <target> agent-drop-ingest --file <staged> --dest <remoteDir> [--name-it]`.
4. Ingest script: optional naming → sanitize → timestamp-prefix → collision check
   → `mv` into `remoteDir` → **echo the final absolute path on stdout**.
5. Windows reads that path → clipboard.
6. **Only now** `afterTransfer` fires (archive / delete / keep).
7. State file updated.

**Failure at any step:** file stays put, error logged, retried on the next poll,
**nothing removed locally.** Filenames are passed as quoted argv, never
interpolated into a remote shell string.

State file is keyed on path + size + mtime so restarts are idempotent.

## 8. Delete-on-source semantics

"Successful transfer" means **steps 2–5 all succeeded**, not `scp` exit 0.
Deleting after the copy but before the rename would lose the file's association
entirely — which is the whole point of the feature.

The old `screenpresso-localsend` **delete-mirroring is deliberately NOT carried
over.** In that tool, "file gone from disk → send a delete marker" would combine
with delete-on-source to delete the file on agent-dev too, on the very next poll.
Those two behaviours are mutually exclusive; this design keeps only
delete-on-source, so the trap cannot occur.

## 9. Naming stage

- `claude -p "<prompt>" --allowedTools Read < /dev/null`, absolute path, hard
  timeout ~60s.
- **Type-gated** by `namingExtensions`: images by extension; text
  (`.txt`/`.log`/`.md`) truncated to the first ~8 KB so a 50 MB log is not read
  whole; everything else (`.zip`, `.pdf`, binaries) skips naming rather than
  burning seconds to name it badly.
- Output sanitized to `[a-z0-9-]`, length-capped, **original extension preserved**.
- Timestamp prefix `YYYYMMDD-HHMMSS-` makes collisions effectively impossible;
  the script still checks and suffixes if one occurs.
- **Any** failure — timeout, missing `claude`, unparseable output, no auth —
  falls back to the original filename and still completes the transfer.
  Naming can never cost the user the file.

**Privacy note the user accepted knowingly:** `claude -p` is *not* local. Images
and logs go to Anthropic, billed against the subscription rather than an API key.
Judged acceptable because it is the same already-sanctioned channel as pasting a
screenshot into Claude Code on the work box. The "nothing leaves the LAN"
property of the rejected Ollama option is gone.

## 10. Testing & phasing

- **`agent-drop-ingest`** — tested on `srvdmsk8s01` with a stubbed `claude` on
  `PATH` echoing a fixed name: collision suffixing, sanitization, path-traversal
  refusal, naming-off path, `claude`-missing fallback, minimal-`PATH` case.
- **PowerShell** — stubbed `scp`/`ssh` asserting argv, clipboard content and
  state transitions. This is the pattern that already caught bugs in
  `screenpresso-localsend`.
- **Phase 1** — transport + multi-folder + archive/delete. Works at work today.
- **Phase 2** — naming stage.
- **Phase 3** — home box, after verification (§11.3).

Phasing exists so the unverified home path never blocks the part that works.

## 11. Open items — MUST be resolved before implementation

1. **`remoteDir` on `srvdmsk8s01`** — needs to be a path something on that box
   already watches, or the pasted paths are useless. Proposed default:
   `~/agent-inbox`, plus `~/agent-inbox/shots` and `~/agent-inbox/logs`.
   **Unanswered.**
2. **Approval of the design**, including a chance to flip D6 (archive vs delete
   default) and D7 (single-phase clipboard). **Unanswered.**
3. **Home box, Phase 3 only** — `agent-dev-home` = `192.168.1.108`, user `freax`,
   auth via `~/.ssh/id_ecdsa` + `id_ecdsa-cert.pub` (**opkssh/Authentik
   short-lived cert**). Unreachable from the work network this session, so
   **untested**: whether the cert stays valid for an unattended logon task, and
   whether `claude` is installed there at all. A cert expiring is a silent-failure
   mode; the sender should alarm (ntfy) rather than stall quietly.

## 12. Corrections log

- Early probe reported "`claude` NOT installed on `srvdmsk8s01`" and a revised
  Windows-side-naming design was proposed on that basis. **Both were wrong** —
  the probe hit the minimal non-interactive `PATH` (§4, Gotcha 1). The user
  corrected it with a screenshot. Design reverted to D3/D5. Do not repeat the
  bare `command -v claude` check over SSH.
- An earlier assumption that work SSH would be the fragile site (opkssh certs)
  was backwards: **work uses a plain long-lived `id_ed25519`; home is the
  cert-bound one.**
