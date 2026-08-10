# Security policy

## Supported versions

Security fixes are applied to the latest project release. This project currently
targets Apple Silicon and has been verified only with the environment documented
in the README.

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub's security-advisory
feature for the eventual `MES30004E/davinci-resolve-portable-macos` repository.
Do not include proprietary Blackmagic binaries, installers, license information,
or personal filesystem paths. Allow a reasonable period for investigation before
public disclosure.

## Security boundaries

The scripts never require `sudo`, modify `/Library`, disable SIP, bypass TCC,
install a LaunchAgent, or set global DYLD variables. They do create two explicit
symlinks in the invoking user's Library. Existing nonempty data and symlinks to
other locations are stop conditions. Users should inspect scripts, obtain Resolve
only from Blackmagic Design, verify their installer, and keep independent backups.

