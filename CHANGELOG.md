# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Project renamed from `screenpresso-localsend` to `localsend-courier`. The
  scheduled task, the `%LOCALAPPDATA%` data directory and the host systemd units
  (`localsend-courier-receiver.service`, `localsend-courier-delete-watcher.service`)
  carry the new name. Existing installs: stop the task, move the data directory,
  re-run `Install-Sender.ps1`, and re-render the host unit. The `.localsend-delete`
  marker suffix is unchanged.

### Added

- Clipboard-text hotkeys in the sender (`clipboardText` config block, off by
  default): save the clipboard's text to `console-<stamp>.log` and put either the
  Windows path or the host path back on the clipboard, plus a hotkey to open the
  folder. Replaces a standalone AutoHotkey script; the dump syncs and
  delete-mirrors like a capture.
- The sender now watches the clipboard-dump folder in addition to the capture
  folder, so dumps can live somewhere writable — a OneDrive Files On-Demand
  capture folder rejects file creation by anything but the capturing app.
- `INSTALL.md` — prerequisites per side, install, configuration, verification and
  troubleshooting for setting the tool up on new machines.
- `CHEATSHEET.md` — keyboard shortcuts, paths, client and host commands, how to
  read the log, and quick checks.
- `PROJECT-OVERVIEW.md` — purpose, architecture and what is deliberately out of
  scope.
- `.log` added to the default `fileExtensions`.
