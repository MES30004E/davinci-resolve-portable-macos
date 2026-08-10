# Technical notes

## Extraction and discovery

`pkgutil --expand-full` runs in a `mktemp` directory on the startup filesystem.
The search requires a directory named `DaVinci Resolve.app` containing
`Contents/MacOS/Resolve`; it does not assume `ManifestLite.pkg` or a payload
hierarchy. Support directories are discovered by their terminal
`Library/Application Support/Blackmagic Design` path.

## Interposition boundaries

The rewrite function checks a component boundary, preventing accidental rewrites
of paths such as `Blackmagic Designer`. It reports `ENAMETOOLONG` rather than
truncating. Wrapper implementations use `mkdirat`, `fstatat`, and `faccessat` so
they do not recursively call the symbols they interpose.

## Signing

The verified environment requires DYLD environment variables and injected code.
The builder first extracts the main executable's existing entitlements, preserves
them, and adds four code-signing entitlements: JIT, unsigned executable memory,
disabled library validation, and allowed DYLD environment variables. It ad-hoc
signs the dylib and main executable. Before changing the executable it inspects
the original CodeDirectory flags with `codesign -dvv`. If the original signature
has the Hardened Runtime flag, the replacement signature uses `--options runtime`;
otherwise the builder does not add Hardened Runtime artificially. Other
CodeDirectory flags are not claimed to be preserved.

Validation checks the executable and dylib signatures, confirms that the dylib
contains arm64 code, and parses the signed executable's entitlement plist to
require both allowed DYLD environment variables and disabled library validation.

The outer Resolve bundle is not re-signed. Adding a framework changes its sealed
resources, and broad re-signing—especially `codesign --deep`—can rewrite nested
signing state and remove the executable entitlements just applied. The launcher
is edited completely, including its plist and icon, before its one final ad-hoc
bundle signature.

Direct signing on exFAT was unreliable in the verified investigation, so all
mutations and signing happen in local temporary staging. The completed app is
copied to the portable filesystem and its executable/dylib signatures are checked
again before activation.

## Installer and space preflight

The selected package's signing information is displayed using
`pkgutil --check-signature`; a nonzero result stops extraction without assuming a
particular certificate identity. Before expansion, the builder conservatively
budgets three times the package size plus 1 GiB on both local staging and portable
filesystems. After expansion it repeats the check using the expanded tree size
plus 512 MiB. These are safety estimates, not exact future disk-usage promises.

## Privacy and security

The environment variable applies only to the launched Resolve process. There is
no LaunchAgent, system-directory mutation, global DYLD configuration, TCC bypass,
SIP change, or admin operation. The expected removable-volume prompt is preserved.
