# Security

Snapmark has no network code. It reads and writes images on your Mac, runs the system
`screencapture` tool, and runs shell commands only for shortcuts you configure yourself.

## Reporting a vulnerability

Please report security issues privately through
[GitHub's private vulnerability reporting](https://github.com/baney75/snapmark/security/advisories/new)
rather than in a public issue. Expect a reply within a week.

## Local signing certificate

The installer creates a self-signed code-signing certificate so macOS keeps the Screen Recording
permission across updates. It lives in its own keychain at
`~/Library/Application Support/Snapmark/Signing`, is never added to your login keychain or trust
settings, and is used only to sign your local Snapmark build. `uninstall.sh` removes it.
