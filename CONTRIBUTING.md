# Contributing

Thanks for looking. This is a small, security-focused app, so changes are held to a few rules:

- **Read-only stays read-only.** No signing, broadcasting, xpubs, or seeds. See `docs/DESIGN.md`.
- **Tor only.** No new network paths, analytics, or third-party Swift packages.
- **No new storage outside the Keychain.** `scripts/test.sh` enforces this.
- **Tests with the change.** Run `scripts/test.sh` (fast). For networking changes, also run
  `scripts/e2e/run.sh`, which needs `brew install tor` and a network that allows Tor. Use only public test-vector
  addresses in tests.
- **No em dashes** in code, docs, or UI text.

Security problems: please follow [.github/SECURITY.md](.github/SECURITY.md) instead of opening an issue.

By contributing, you agree your contribution is licensed under the MIT license in `LICENSE`.
