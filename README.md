# DaVinci Resolve Portable for macOS


## ⚠️ Important Disclaimer

> **This project was vibecoded with AI assistance and should be treated as experimental community software.**
>
> The scripts modify application bundles, code signatures, environment variables, symlinks, and files on external storage. Although the project has been tested on a real macOS system, bugs, macOS changes, DaVinci Resolve updates, filesystem differences, or unexpected configurations may cause data loss, broken installations, application failures, or other unintended effects.
>
> **Use this code, its scripts, and all commands entirely at your own risk.**
>
> Back up important Resolve projects, databases, preferences, media, and other data before using this project.
>
> The author and contributors provide this software **as-is, without warranty**, and are not responsible for damage, data loss, downtime, or other consequences resulting from its use.
>
> This project is unofficial and is **not affiliated with, endorsed by, or supported by Blackmagic Design**. DaVinci Resolve and related names are trademarks of their respective owners.
>
> This repository does **not** distribute DaVinci Resolve. You must obtain the official macOS installer yourself from Blackmagic Design.

Build a portable, external-drive installation from **your own official DaVinci
Resolve macOS `.pkg` installer**, without `sudo` or an administrator account.

> [!IMPORTANT]
> This is an unofficial community project and is not affiliated with, endorsed
> by, or supported by Blackmagic Design. It does not include or redistribute
> DaVinci Resolve, an installer, Blackmagic support files, or artwork. You must
> obtain the official installer yourself and comply with Blackmagic Design's
> license terms.

The current implementation has been tested with **DaVinci Resolve 21.0.4**, an
**Apple Silicon Mac**, **macOS 26.6.1**, and an **exFAT** external SSD. The builder
detects the installed version rather than hardcoding it, but later Resolve or
macOS releases may require changes.

## What it creates

```text
<portable root>/
├── SSD Apps/
│   └── DaVinci Resolve.app              small no-Terminal launcher
└── Application Support/
    └── Blackmagic Design/
        ├── DaVinci Resolve <version>.app real application
        ├── User/                          mutable user data
        └── User Preferences/              mutable preferences
```

Resolve also requires two tiny local symlinks:

```text
~/Library/Application Support/Blackmagic Design
  -> <portable root>/Application Support/Blackmagic Design/User

~/Library/Preferences/Blackmagic Design
  -> <portable root>/Application Support/Blackmagic Design/User Preferences
```

The builder will create these only when each path is missing or an empty
directory. It stops without deleting anything if real data or another symlink is
present; it does not automatically back up or migrate that data. See
[troubleshooting](docs/troubleshooting.md) for a safe migration plan.

## Requirements

- Apple Silicon Mac (the only currently supported architecture)
- the official DaVinci Resolve macOS `.pkg`
- a writable portable root, normally on an external drive
- Xcode Command Line Tools (`xcrun clang`)
- no administrator password and no `sudo`

Keep a current backup of your Resolve databases, projects, preferences, and the
portable drive. Absolute references are used: changing the external volume's
name or mount path can break the launcher, redirector, and local symlinks. Rebuild
or update after a mount-path change.

## Build

1. Download the official macOS installer from Blackmagic Design.
2. Double-click `Build Portable Resolve.command`.
3. Drag the `.pkg` into the window and press Return.
4. Drag the chosen portable-drive root into the window and press Return.
5. Open `<portable root>/SSD Apps/DaVinci Resolve.app`.

Build mode refuses a root already marked as a project-managed installation. Use
`Update Portable Resolve.command` for that root instead.

On first launch, macOS may request removable-volume permission. This is expected;
choose **Allow**. The project does not bypass macOS privacy controls.

The package is expanded with standard `pkgutil --expand-full`. The builder finds
the app rather than assuming a package component layout, reads
`CFBundleShortVersionString`, builds the redirector from source on local storage,
embeds it in the real app's `Contents/Frameworks`, and generates the launcher.
Before extraction it displays `pkgutil --check-signature` results and performs
conservative free-space checks on both staging and destination filesystems.
Build and update show a live phase-based dashboard. Measurable copies include
byte progress, current-file activity, transfer rate, and remaining `Time left`;
the overall estimate is approximate. Set `DAVINCI_PORTABLE_NO_ANIMATION=1` to
keep ordinary status lines without animated terminal output.

## Update, diagnose, and uninstall

- Run `Update Portable Resolve.command` with a newer official `.pkg`. User data
  remains outside the versioned app. The guided updater auto-detects managed
  portable roots, compares installed and incoming versions, and requires explicit
  confirmation for repairs or downgrades. The new app is staged and validated
  before activation, with a comprehensive timestamped rollback retained by
  default.
- Run `scripts/diagnose.command <portable-root>` for a read-only report. Add
  `--dyld-test` as the second argument only if you intentionally want it to offer
  to launch Resolve with library-load logging.
- Run `Uninstall.command`. It removes only matching project symlinks and owned
  generated files, then asks separately before deleting portable user data.

More detail: [updating](docs/updating.md), [how it works](docs/how-it-works.md),
and [technical notes](docs/technical-notes.md).

## Safety and limitations

- Never run these scripts against a drive without a backup.
- Resolve itself may store media, caches, galleries, databases, or project
  libraries at locations you configure separately; portability is not a backup.
- The outer Resolve bundle is not gratuitously re-signed. Only the embedded dylib
  and the main executable are ad-hoc signed. Existing executable entitlements are
  preserved and augmented; Hardened Runtime is retained only when the source
  signature already has it. Other CodeDirectory flags are not promised to be
  preserved. Signing behavior can change in future macOS/Resolve releases.
- The repository intentionally ignores `known-good/`, `*.pkg`, `*.dylib`, and
  `*.app/`; do not publish reference or generated proprietary artifacts.

## Development

Run the safe workspace-only suite on macOS:

```sh
./tests/run.sh
```

The code in this repository is licensed under the [MIT License](LICENSE).
