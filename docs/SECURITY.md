# Security

## What this protects

| Asset | If exposed |
|---|---|
| Watched addresses and balances | Someone learns what you hold at those addresses |
| Onion address + client auth key | Someone can query your electrs, and learn nothing about your wallet by doing so. It can cost your server resources |
| Your coins | **Not at risk from this app.** It has no keys and can't sign |

## Threats and controls

| Threat | Control | Checked by |
|---|---|---|
| Network observer learns the node's location or your addresses | All traffic is inside Tor. There's no other connection code | E2E test; review |
| App accidentally connects outside Tor | No `URLSession`, no IP sockets; Unix socket only; `OnionTrafficOnly`; ATS left at its default | `scripts/test.sh` grep check; E2E |
| Stranger finds the onion address | Client auth: without the key, the service's descriptor can't be decrypted | E2E negative test |
| Other app on the phone talks to Tor | No TCP ports. Unix sockets in the sandbox | Review; `lsof` check in E2E |
| Stolen unlocked phone, or someone who knows the passcode | `.biometryCurrentSet`, lock on background | Device test (M5) |
| Stolen locked phone | Keychain item needs Face ID. Tor's files only hold public network data, under `completeFileProtection` | Device test (M5) |
| Backup or iCloud leak | `ThisDeviceOnly`, and Tor's directory is excluded from backups | Device test (M5) |
| Malicious keyboard | Third-party keyboards blocked | Device test (M5) |
| Screenshots in app switcher | Cover shown when inactive, including over sheets | Device test (M5) |
| Clipboard snooping | The app never writes to the clipboard. Only the public key can be selected | `scripts/test.sh` grep check; review |
| Malicious server reply | Size limits, timeouts, strict decoding, range checks, no server text shown | Unit tests |
| App tricked into spending | No such code | Unit tests; E2E method allowlist |
| Compromised dependency | One dependency, pinned by checksum and commit | `VENDORED.md` |
| Tor vulnerability | Update the pinned version and rebuild. Follow the update steps below | Process |

## Accepted risks

- **R1: Tor is a prebuilt binary we can't reproduce.** SwiftPM verifies the checksum, but upstream doesn't offer reproducible builds, so we
  trust the maintainer who built it. Orbot's users trust the same maintainers. To remove this later, build it
  from source using upstream's `build-xcframework.sh`, on a machine with enough memory.
- **R2: A compromised node could show false balances.** v1 trusts your server, because it has no proof of work or merkle checks. It can't
  move coins, but it could hide a theft. If the node's audit (`node-audit`) ever fails, don't rely on this app. Checks can be added later (M6).
- **R3: Secrets in memory.** Swift can't guarantee wiping memory, so we drop references when locking rather than claiming secure erase. Tor also holds
  the key until it's removed on background. A full device compromise defeats this and everything else in the app.
- **R4: Not a compromised-iOS defense.** A jailbroken phone or an OS-level exploit can read what the app displays. Lockdown Mode is worth
  considering if that's in your threat model.
- **R5: Your own screenshots.** iOS doesn't let apps block these.
- **R6: Tor client auth uses x25519,** which isn't post-quantum. This matches Tor itself, and the data at stake is privacy, not funds.
- **R7: Signing depends on you.** The app is installed from your own Mac using your paid Apple developer account, with no App Store review. Nothing is
  distributed publicly. `scripts/release-build.sh` makes a Release Testing (Ad Hoc) build for registered devices, which a debugger can't attach to. When
  its profile expires the app stops opening, so rebuild and install over it. The script prints the expiry date.

## Updates

**Tor is compiled into the app, so `apt` on the node doesn't patch it.**

| When | What |
|---|---|
| Monthly, and on any Tor security announcement | Check [Tor.framework releases](https://github.com/iCepa/Tor.framework/releases) and [Tor news](https://blog.torproject.org/). Update per `VENDORED.md` |
| When a Tor security release is out | Rebuild and reinstall within the same targets as the node (see the mini-pc `SECURITY-PLAN.md`) |
| Each iOS update | Run the app, confirm unlock and refresh still work |

## Incident response

| Event | Do this |
|---|---|
| Phone lost or stolen | **Disable the electrs onion service in `torrc`** and restart Tor, then remove the phone's file from `/var/lib/tor/electrs/authorized_clients/`. Removing only the file is unsafe: with no client files left, Tor stops requiring client auth and the service becomes open to anyone with the address. Use Find My to erase the phone |
| Key might be exposed | Use Settings > Erase Everything, set up again, then put the new phone's public key in `iphone.auth`, replacing the old line, and restart Tor |
| Onion address might be exposed | No urgent action, since client auth still protects it. Rotate it at your convenience |
| `node-audit` fails | Don't trust balances from this app. Follow the node's incident plan |
