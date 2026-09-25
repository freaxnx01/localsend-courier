# TODO

## Session 2026-09-25 (Screenpresso / Transfer folder, #6) — scoping checked, #6 still needs enrichment

- [ ] Commit or drop the uncommitted `.gitignore` change (adds `.worktrees/`). It predates this session and is still unstaged on `main`.
- [ ] Prune the stale worktree record `C:/Develop/GitHubRepos/freaxnx01/public/screenpresso-localsend/.worktrees/new` (branch `worktree-new`, 944e211). The directory no longer exists since the rename, so `git worktree prune` clears it. Check first whether branch `worktree-new` has anything worth keeping.
- [ ] Knowledge-base vault `shared/DMS Team Members/ANIM/TODO.md:22` ("Screenpresso: auto-transfer to configured host via LocalSend") is done via localsend-courier. Tick it and link this repo. Line 52 ("LocalSend File transfer") may be covered too.
- [ ] #6 (generic Transfer folder, decoupled from Screenpresso): run `/enrich 6`. Context not in the issue: the clipboard dumps already moved out of the Screenpresso folder to `%LOCALAPPDATA%\localsend-courier\clips` (commit 2d554b1), and the sender already watches two folders. So "watch both" is the existing pattern to build on.
