# Changelog

All notable changes to this project will be documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed

- Fixed GitHub Actions dashboard tests inheriting no-animation mode.

## [0.3.0] - 2026-08-11

### Added

- Initial no-admin builder for user-supplied DaVinci Resolve macOS packages.
- Portable updater with local staging, validation, and rollback retention.
- Conservative uninstaller and read-only diagnostic report.
- Source-built arm64 filesystem redirector and no-Terminal launcher.
- Workspace-only unit and dry-run tests.

### Changed

- Preserve Hardened Runtime when it exists on the source Resolve executable,
  without adding it to executables that did not have it.
- Validate required DYLD/library-validation entitlements, arm64 redirector
  architecture, and both executable signatures before activation.
- Refuse Build mode on an existing managed portable root.
- Display installer-signature information and perform conservative local and
  portable free-space checks before installation.
- Suppress normal launcher output while retaining opt-in diagnostic logging.
- Remove unused automatic pre-install backup restoration from the uninstaller.
- Add a live terminal dashboard with monotonic phase progress, real current-file
  activity, measured copy progress, and remaining-duration `Time left` estimates;
  retain concise status output in noninteractive and nonanimated modes.
- Fix human-readable free-space formatting on stock macOS BSD `awk`.
- Add a guided updater with marker-based mounted-volume discovery, safe dragged
  path normalization, same-version repair and downgrade confirmations, an
  installed-updater self-copy fix, and comprehensive automatic rollback for the
  app, launcher, support payloads, and project state.
- Keep automated release introductions brief and direct users to README/docs.
