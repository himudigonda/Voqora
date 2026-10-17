# Security Policy

## Supported versions

Only the latest release of Voqora receives security fixes.

## Reporting a vulnerability

Please do not open a public issue for a security problem. Use GitHub's private
reporting: **Security -> Report a vulnerability** on
<https://github.com/himudigonda/Voqora/security/advisories/new>.

Include the Voqora version, macOS version, and steps to reproduce. I aim to
acknowledge a report within 7 days and to ship a fix for confirmed issues as
soon as practical. Please give me reasonable time to fix before sharing details.

## Scope

In scope: the app, the bundled local speech server, the in-app installer and
update check, and the release artifacts on GitHub.

The speech server listens only on 127.0.0.1, on a random port, and requires a
fresh secret token on every request. Reports that show a way around that
protection are especially welcome.
