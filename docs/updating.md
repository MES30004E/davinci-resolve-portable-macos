# Updating

Use a fresh official DaVinci Resolve macOS `.pkg` and run
`Update Portable Resolve.command`. The updater repeats package discovery and
version detection instead of assuming a version or component hierarchy.

The replacement app is built on the local startup filesystem, including the
root-specific redirect dylib and executable signing. It is then copied to a
temporary incoming path on the portable filesystem and validated there. Only
after that validation does the updater move the current app into
`.davinci-resolve-portable/rollback/` and activate the incoming app. If activation,
post-copy validation, or launcher generation fails, it restores the prior app.

`User` and `User Preferences` are outside the versioned application. Installer
payload entries with either reserved name are skipped, so updates do not merge
over them. Before other package-managed top-level support payloads are refreshed,
the updater copies their complete existing state into the rollback directory. An
exit trap restores that state if any later update step fails.

The app and support-payload rollback is retained after success. Once the new Resolve version
has been tested and your independent backup is current, old rollback applications
can be removed manually. Never remove `User` or `User Preferences` as part of
routine cleanup.
