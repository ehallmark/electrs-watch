# Reporting a vulnerability

Please report security problems privately, through GitHub's
[private vulnerability reporting](https://github.com/ehallmark/electrs-watch/security/advisories/new),
not in a public issue.

Include what you found, how to reproduce it, and what an attacker could do with it. You'll get a reply
within a week. Please give a fix time to ship before you publish details.

Useful areas to look at: anything that could make the app connect outside Tor, write secrets outside the
Keychain, send an Electrum method other than the read-only ones, or trust a malformed server reply.
The threat model and accepted risks are in [docs/SECURITY.md](../docs/SECURITY.md).
