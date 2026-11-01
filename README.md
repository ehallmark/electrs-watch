# electrs-watch

**Nightwatch** on the home screen, with a Night's Watch theme for personal use. The theme uses *Game of Thrones* references, so
replace it before any public release. `electrs-watch` stays as the repo and project name, and the bundle ID doesn't change.

A small iPhone app that shows the balance of Bitcoin addresses you choose, using your own electrs
server over a private Tor onion service.

- **It can't spend.** It holds no wallet keys and has no code to sign or broadcast transactions.
- **Tor is built in.** You don't need Orbot or a VPN. The app has no way to make a connection outside Tor.
- **Only your phone can reach the server.** It uses Tor client authorization, and the key stays in
  the iOS Keychain behind Face ID.
- **Addresses only, no xpub.** A leaked phone exposes the addresses you entered, not your whole wallet.

**The balance is "what's at these addresses", not your wallet total.** When you spend, change usually
goes to a new address that this app doesn't know about until you add it.

## Documents

| Document | What it covers |
|---|---|
| [docs/DESIGN.md](docs/DESIGN.md) | Architecture, data flow, and the reasons behind the choices |
| [docs/SECURITY.md](docs/SECURITY.md) | Threat model, controls, accepted risks |
| [docs/PLAN.md](docs/PLAN.md) | Milestones and current status |
| [docs/NODE-SETUP.md](docs/NODE-SETUP.md) | Enabling the private electrs onion service and pairing a phone |
| [Vendor/TorFramework/VENDORED.md](Vendor/TorFramework/VENDORED.md) | Where the Tor library comes from and how to update it |

## Build and test

Needs Xcode 26.3 or later.

```sh
scripts/test.sh          # unit tests for the core logic (no Tor, no simulator)
scripts/e2e/run.sh       # full test in the simulator, over the real Tor network, with a mock server
open ElectrsWatch.xcodeproj
```

`scripts/e2e/run.sh` needs `brew install tor`. It only uses public test-vector addresses.
