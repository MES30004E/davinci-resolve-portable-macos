# Contributing

Thank you for helping make portable Resolve safer and more predictable.

Before opening a change, read `CONTEXT.md`, the documents under `docs/`, and the
security boundaries in `SECURITY.md`. Never add an installer, Resolve app,
Blackmagic binary, icon, generated dylib, crash log containing private paths, or
portable distribution to a commit.

Use a feature branch, keep changes focused, and run:

```sh
./tests/run.sh
```

Tests must use fake directory trees inside the repository. Do not point tests at
`~/Library`, `/Library`, or a real portable installation. Pull requests should
explain macOS version, architecture, filesystem, Resolve version, and whether any
signing behavior changed. A human must test real installers and removable drives.

