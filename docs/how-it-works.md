# How it works

Resolve expects part of its support tree at the system path
`/Library/Application Support/Blackmagic Design`, which a non-admin user cannot
create. A small dynamic library interposes exactly four C library calls used by
the verified installation: `mkdir`, `stat`, `lstat`, and `access`. Paths equal to
that prefix, or below it at a path-component boundary, are rewritten to the
selected portable support directory. Other paths pass through unchanged.

The destination is compiled into the dylib for each selected portable root. The
dylib lives inside the real Resolve app at
`Contents/Frameworks/resolve-redirect.dylib`. Keeping it in the app bundle is
important: a dylib elsewhere on a removable exFAT volume was observed to fail
with a DYLD `file system sandbox blocked open()` termination.

The real app stays under `Application Support/Blackmagic Design`. The item in
`SSD Apps` is a small `osacompile` AppleScript app. It starts the real executable
directly with a process-local `DYLD_INSERT_LIBRARIES` value, so no Terminal window
or global environment change is needed. The launcher's icon is copied from the
user's extracted official app and is never stored in this repository.

Mutable per-user state uses two local symlinks documented in the README. These
are the only objects created outside the portable root during a real build. The
builder classifies each existing path before changing it and refuses ambiguous or
data-bearing states.

