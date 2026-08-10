# Troubleshooting

## Existing Blackmagic Design data

If the builder reports a nonempty directory, it deliberately stops. Quit Resolve
and make a verified backup first. Inspect both reported user-Library paths. A safe
migration is to copy—not move—the existing content into the corresponding
portable `User` or `User Preferences` directory, verify the copy independently,
then rename the original directory to a clearly dated backup. Rerun the builder
only when the original path is missing or empty. Keep the backup until Resolve
has opened your projects and preferences successfully.

The builder does not automatically rename, migrate, or back up these existing
directories, and the uninstaller therefore has no automatic pre-install backup
restoration path. This is intentional: ambiguous user data is never moved by the
project.

The project will not replace a stale/broken symlink that points elsewhere. Record
its target and decide whether it belongs to another installation before changing
it manually.

## “App is damaged,” signature errors, or immediate termination

Run `scripts/diagnose.command` against the portable root. Check the dylib and
Resolve executable architecture, ad-hoc signature, required entitlements, and
strict validation output. Do not use `codesign --deep`, disable SIP, remove
quarantine indiscriminately, or weaken system security. Rebuild from a fresh
official package on the same Mac.

## Removable-volume prompt

A first-launch prompt is expected. Choose Allow. If access was denied, review the
app's Files and Folders permission in System Settings. The project does not and
should not bypass TCC.

## Drive renamed or mounted somewhere else

The launcher, embedded redirector, and two symlinks contain absolute paths. Put
the volume back at its original name/mount path, or rebuild/update for the new
path after backing up user data.

## No compiler

The builder uses the Apple compiler through `xcrun`. Install Apple's Command Line
Tools using Apple's supported mechanism, then retry. The project does not install
packages through Homebrew or another package manager.

## Diagnostic library-load test

Normal diagnosis is read-only. `diagnose.command <root> --dyld-test` offers an
explicit optional launch with `DYLD_PRINT_LIBRARIES`; output goes to
`/tmp/davinci-resolve-portable-dyld.log`. It never runs unless you confirm.
