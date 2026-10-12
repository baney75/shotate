# Security

Shotate makes one kind of network request: the update check, an HTTPS download of a small
`manifest.json` from the project's GitHub releases, with no identifiers, once a day and when you ask.
Turn it off with `"checkForUpdates": false` and Shotate makes none. Otherwise it reads and writes
images on your computer, captures the screen, and runs shell commands only for shortcuts you
configure yourself.

Updates are verified before they run: on Windows and Linux the installer's SHA-256 must match the
manifest; on macOS the update is built from the release's tagged source (or, on the nightly
channel, the exact commit), the same way the install command builds it.

## Reporting a vulnerability

Please report security issues privately through
[GitHub's private vulnerability reporting](https://github.com/baney75/shotate/security/advisories/new)
rather than in a public issue. Expect a reply within a week.

## Local signing certificate

The installer creates a self-signed code-signing certificate so macOS keeps the Screen Recording
permission across updates. It lives in its own keychain at
`~/Library/Application Support/Snapmark/Signing` (the folder keeps the app's old name), is never added to your login keychain or trust
settings, and is used only to sign your local Shotate build. `uninstall.sh` removes it.

The tradeoff: the key and its keychain password are files readable by your user account. A program
already running as you could use them to sign its own code as Shotate and inherit Shotate's Screen
Recording permission. That program could also just ask you for the permission, so this adds little
risk on a single-user Mac, but you should know about it. The keychain locks itself five minutes after
each build. If you would rather not keep a key, build with `SHOTATE_ADHOC=1 make install`; macOS
will then ask for Screen Recording again after each update.
