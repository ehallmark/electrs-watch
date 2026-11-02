# Design

## Goal

Answer one question from an iPhone, away from home: **"Are my coins still where I left them?"**

### In scope (v1)

- Balance (confirmed and pending), transaction count, and latest activity for addresses you enter
- Chain tip height, so you can tell the server is current
- Connecting only to your own electrs, only over an authorized onion service

### Out of scope, on purpose

| Not included | Why |
|---|---|
| Private keys, signing, broadcasting | This is what makes it read-only |
| xpub/descriptor import | A leak would expose every past and future address |
| Public or third-party servers | They would learn your addresses |
| Clearnet connections, push notifications, widgets, analytics, crash reporting | Each one is a way for data to leave the app |
| Third-party Swift packages other than Tor | Less code to trust |
| Fiat prices | Would need a connection to someone else's server |

## Architecture

```
 iPhone app process
 +--------------------------------------------------------------+
 |  SwiftUI views                                               |
 |      |                                                       |
 |  AppModel (state, lock, refresh)                             |
 |      |              |                     |                  |
 |  KeychainVault   TorService          WatchCore               |
 |  (Face ID item)  (runs tor thread)   (addresses, SOCKS,      |
 |                     |                 Electrum client)       |
 |                     | control socket      | SOCKS socket     |
 |                     v (Unix socket)       v (Unix socket)    |
 |                  +---------------------------+               |
 |                  |    Tor 0.4.9.15 (thread)  |               |
 |                  +-------------+-------------+               |
 +--------------------------------|-----------------------------+
                                  | Tor network, end-to-end encrypted
                                  v
 Mini PC:  tor onion service (client auth) -> 127.0.0.1:50001 electrs -> Bitcoin Core
```

## Key decisions

### 1. Embed Tor rather than depend on Orbot

Orbot ([source](https://github.com/guardianproject/orbot-apple)) is a good app and we learned from it, but
it serves a different need.

| | Orbot + a wallet app | Embedded Tor (this app) |
|---|---|---|
| Fails open if Tor is off | Depends on the other app | Can't: the app has no other route |
| Client auth key held by | Orbot, in its files | Only this app, in memory while unlocked |
| Runs in the simulator | No: [Network Extensions need a real device](https://github.com/guardianproject/orbot-apple#build) | Yes |
| Other apps' traffic | Goes through Tor too | Unaffected |
| Memory limit | About 50 MB for the extension | Normal app limit |

Both use the same library, iCepa's [Tor.framework](https://github.com/iCepa/Tor.framework), so this doesn't add a new Tor
implementation to trust. We use C Tor and not Arti: the Arti build is marked experimental upstream.

### 2. No TCP ports on the phone

iOS apps can reach each other's loopback TCP ports. So Tor's SOCKS and control interfaces are Unix sockets in
this app's private container, which other apps can't open. The SOCKS port also sets `OnionTrafficOnly`,
so Tor refuses anything but onion destinations, even if the app had a bug.

### 3. Tor client auth key stays out of files

Tor's usual `ClientOnionAuthDir` keeps the private key in a plain file. We leave it unset and give the key
to Tor with the control command `ONION_CLIENT_AUTH_ADD` (no `Permanent` flag), which keeps it in memory. The
key's only stored copy is in the Keychain. We confirmed this against Tor 0.4.9.15: nothing about the key or address reaches its data directory.

The phone generates the key, and only the public half ever leaves it. You add that public half to the node.

### 4. One Keychain item holds everything sensitive

The onion address, client auth key, watched addresses, display unit, last fetched balances, and connection counts live in one JSON value in one Keychain item:

- `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly`: not in iCloud Keychain or backups, and deleted if the passcode is removed
- `.biometryCurrentSet`: reading it takes Face ID, and enrolling a new face makes it permanently unreadable

Someone who learns your passcode can't enroll their own face and open it. The cost is that a Face ID change
means setting up again: new key, and update the node. That's acceptable for an app that can't lose funds.

Balances are only stored in that item, so reading the saved copy takes Face ID. It's for display: it's dimmed and labeled until a refresh succeeds, and
changing the onion address deletes it. Damage to the saved balance, unit, or connection counts is ignored on read, because an unreadable vault offers to erase the client key.

Settings shows the connection counts, one per kind of outcome, to help explain slow connections. They hold no addresses, times, or server text, and never leave the phone.

### 5. Read-only by construction

`ElectrumRequest` is a closed Swift enum with five cases: `server.version`, `blockchain.headers.subscribe`,
`blockchain.scripthash.subscribe`, `blockchain.scripthash.get_balance`, `blockchain.scripthash.get_history`.
Subscribing only asks the server to track an address, which lets electrs reuse one status for both queries.
There's no generic "send any method" function, so calling `blockchain.transaction.broadcast` would need a code change. The E2E mock server records
every method and the test fails on any other.

### 6. Treat the server's replies as untrusted

Even our own server could be compromised, so its input is limited:

- Maximum line size (4 MiB). Longer replies are an error, and memory stays bounded
- A 60-second deadline for each whole call, so a server can't stall by sending slowly
- Reply IDs must match. Notifications are ignored, with a cap
- Strict decoding, plus range checks: balances can't exceed 21 million BTC, and transaction IDs must be 64 hex characters
- All amounts are integer satoshis, never floating point
- Server text is never displayed. Errors show our own message

The app doesn't verify merkle proofs or proof of work in v1, so a compromised server could show false
balances. See `docs/SECURITY.md`, accepted risk R2.

### 7. Lock on leaving

| Event | What happens |
|---|---|
| App inactive (app switcher, Control Center) | A cover hides the screen, including from the app switcher snapshot |
| App in background | Close server connection; remove key from Tor; `DisableNetwork 1`; drop vault contents and balances from app state; invalidate Face ID context |
| Back in foreground | Requires Face ID. Unlocking shows the saved balance and, if there are watched addresses, refreshes right away: this turns the network on, re-adds the key, and reconnects, retrying for up to about 4 minutes before showing a failure. With no addresses, Tor stays off until you tap Refresh |

Tor keeps running because [one process can only start it once](https://github.com/iCepa/Tor.framework/blob/spm/Sources/CTor/TORThread.m).
`DisableNetwork` stops all its traffic while the app is backgrounded. It also starts with the network off, so nothing happens until an unlocked session asks.

Each connection attempt times out after 60 seconds. An attempt that took 20 seconds or more counts as stuck, so before the next attempt the app removes the key and turns Tor's network off and on, the same reset a lock and unlock causes. Faster failures retry without a reset, because they usually pass quickly and a reset would bring back the moment right after Tor resumes. No new attempt starts after 3 minutes.

A lock has to win against work already in progress. Tor commands run through a single queue, in an order fixed at the moment they're
queued, and anything that exposes something first checks that its session hasn't been locked. The app also asks iOS for background time, so the cleanup commands get to finish.

### 8. Input safety

- Third-party keyboards are disabled in this app, since they can log keystrokes.
- Fields turn off autocorrect and suggestions.
- The app doesn't write to the clipboard. The public key can be selected or sent with the share sheet, because it's public. Nothing else can be selected.
- Only mainnet addresses are accepted, with full checksum validation: P2PKH, P2SH, P2WPKH, P2WSH, and P2TR.

## Protocol details

electrs 0.12.0 [speaks Electrum protocol 1.4](https://github.com/romanz/electrs/blob/v0.12.0/src/electrum.rs). Newline-delimited JSON-RPC over plain TCP inside the onion
circuit. Onion services are encrypted end-to-end and the address authenticates the server, so TLS would add nothing.

```
-> {"id":1,"jsonrpc":"2.0","method":"server.version","params":["electrs-watch","1.4"]}
<- {"id":1,"jsonrpc":"2.0","result":["electrs/0.12.0","1.4"]}
-> {"id":2,...,"method":"blockchain.headers.subscribe","params":[]}
-> {"id":3,...,"method":"blockchain.scripthash.subscribe","params":["<scripthash>"]}
-> {"id":4,...,"method":"blockchain.scripthash.get_balance","params":["<scripthash>"]}
-> {"id":5,...,"method":"blockchain.scripthash.get_history","params":["<scripthash>"]}
```

The scripthash is `SHA256(scriptPubKey)` with the bytes reversed. The server sees it, which reveals the address to
the server. That's fine, because the server is yours.

SOCKS5 with Tor's `ExtendedErrors` gives specific failures, so the app can show "this phone isn't authorized" (`0xF4`, `0xF5`) instead of
a generic timeout. After such a failure, Retry sends `SIGNAL NEWNYM`, which makes Tor discard its cached copy of the service
descriptor and fetch the one that includes the new key.

## Code layout

| Path | Contents |
|---|---|
| `Packages/WatchCore` | All logic without UI or Tor. Builds and tests on macOS in seconds |
| `App/` | SwiftUI, Keychain, and Tor lifecycle |
| `TorControl.swift` (in WatchCore) | Our own small Tor control client. It replaces the wrapper's `TORController`, which routes replies newest-first and can't detect a closed connection |
| `UITests/` | The simulator E2E test |
| `Vendor/TorFramework` | Pinned Tor wrapper and binary reference |
| `scripts/e2e` | Temporary onion service and mock electrs for E2E |

## Limits

- First Tor start can take about a minute. Later starts reuse the cached directory data.
- Refresh only runs while the app is open. There are no background checks or alerts.
- The balance only covers the addresses you entered (see README).
