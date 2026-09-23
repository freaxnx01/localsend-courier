# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Clipboard-text hotkeys in the sender (`clipboardText` config block, off by
  default): save the clipboard's text to `console-<stamp>.log` in the watched
  folder and put either the Windows path or the host path back on the clipboard,
  plus a hotkey to open the folder. Replaces a standalone AutoHotkey script; the
  dump syncs and delete-mirrors like a capture.
- `INSTALL.md` — prerequisites per side, install, configuration, verification and
  troubleshooting for setting the tool up on new machines.
- `PROJECT-OVERVIEW.md` — purpose, architecture and what is deliberately out of
  scope.
- `.log` added to the default `fileExtensions`.
