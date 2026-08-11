# Updating

Double-click `Update Portable Resolve.command`. The guided updater searches only
mounted volumes and their immediate top-level folders for valid project ownership
markers. One valid installation is selected automatically; multiple installations
are listed for selection; if none is found, you can drag or paste the managed
portable root. Unmanaged or invalid roots are rejected.

The updater displays and validates the current version/app before asking for a
new official `.pkg`. Plain, quoted, and Finder backslash-escaped paths are
accepted. Incoming versions are compared numerically: newer versions proceed,
same-version repair requires confirmation, and downgrades require separate
confirmation. Both confirmation prompts default to No.

The replacement app is built on the local startup filesystem, including the
root-specific redirect dylib and executable signing. It is then copied to a
temporary incoming path on the portable filesystem and validated there. Only
after that validation does the updater create a timestamped comprehensive backup
under `.davinci-resolve-portable/rollback/update-<timestamp>/` and change the live
installation. The backup contains the current app, launcher, replaced support
payloads, and project state/runtime files.

`User` and `User Preferences` are outside the versioned application. Installer
payload entries with either reserved name are skipped, so updates do not merge
over them. Before other package-managed top-level support payloads are refreshed,
the updater copies their complete existing state into the rollback directory.
`User` and `User Preferences` are explicitly excluded. An exit trap restores the
previous app, launcher, support payloads, and state if any later phase fails, then
validates the restored installation.

The rollback is retained after success unless you explicitly accept the final
delete prompt. Older backups are never removed automatically. Never remove `User`
or `User Preferences` as part of routine cleanup.
