# Security

Shotate has no network code. It reads and writes images on your Mac, runs the system
`screencapture` tool, and runs shell commands only for shortcuts you configure yourself.

## Reporting a vulnerability

Please report security issues privately through
[GitHub's private vulnerability reporting](https://github.com/baney75/shotate/security/advisories/new)
rather than in a public issue. Expect a reply within a week.

## Local signing certificate

The installer creates a self-signed code-signing certificate so macOS keeps the Screen Recording
permission across updates. It lives in its own keychain at
`~/Library/Application Support/Shotate/Signing`, is never added to your login keychain or trust
settings, and is used only to sign your local Shotate build. `uninstall.sh` removes it.

The tradeoff: the key and its keychain password are files readable by your user account. A program
already running as you could use them to sign its own code as Shotate and inherit Shotate's Screen
Recording permission. That program could also just ask you for the permission, so this adds little
risk on a single-user Mac, but you should know about it. The keychain locks itself five minutes after
each build. If you would rather not keep a key, build with `SHOTATE_ADHOC=1 make install`; macOS
will then ask for Screen Recording again after each update.
