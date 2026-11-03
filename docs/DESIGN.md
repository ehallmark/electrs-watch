# Design

## Goal

Answer one question from an iPhone, away from home: **"Are my coins still where I left them?"**

### In scope (v1)

- Balance (confirmed and pending), transaction count, and latest activity for addresses you enter
- A page per address with its transactions, each one's amount, and a balance-over-time chart
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

### 4. Keychain items hold everything sensitive

The onion address, client auth key, watched addresses, display unit, last fetched balances, and connection counts live in one JSON value in one Keychain item. Saved address pages (each address's recent transactions) live in a second item with the same protection, so the first stays small. Both items are:

- `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly`: not in iCloud Keychain or backups, and deleted if the passcode is removed
- `.biometryCurrentSet`: reading it takes Face ID, and enrolling a new face makes it permanently unreadable

Someone who learns your passcode can't enroll their own face and open it. The cost is that a Face ID change
means setting up again: new key, and update the node. That's acceptable for an app that can't lose funds.

The only thing kept outside the Keychain is the light or dark setting, in UserDefaults, because the lock screen needs it before Face ID. It says nothing about your coins or server. `scripts/test.sh` fails on any other use of UserDefaults.

The second item holds the 20 most recently loaded address pages, compressed, and is read with the same unlock, so there's no second prompt. It's emptied when the onion address changes, loses a page when its address is removed, and goes with Erase Everything. If it can't be read, it's treated as empty, since the pages can always be fetched again. A saved page is shown without connecting while it still matches the latest balance, transaction count, and block height; otherwise the page shows it and fetches a new one.

Balances are only stored in that item, so reading the saved copy takes Face ID. It's for display: it's dimmed and labeled until a refresh succeeds, and
changing the onion address deletes it. Damage to the saved balance, unit, or connection counts is ignored on read, because an unreadable vault offers to erase the client key.

Settings shows the connection counts, one per kind of outcome, to help explain slow connections. They hold no addresses, times, or server text, and never leave the phone.

### 5. Read-only by construction

`ElectrumRequest` is a closed Swift enum with seven cases: `server.version`, `blockchain.headers.subscribe`,
`blockchain.scripthash.subscribe`, `blockchain.scripthash.get_balance`, `blockchain.scripthash.get_history`,
`blockchain.transaction.get` (raw form only), and `blockchain.block.header`. All of them only read.
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
- Raw transactions are parsed with bounds checks on every length and count, and each is hashed on the phone
  and must match the ID it was requested by, so a server can't swap one transaction for another
- Transaction amounts are worked out on the phone: coins paid to the address, minus its coins spent.
  Balances are walked back from the server's current balance, and when the whole history is shown the walk
  has to end at exactly zero, or the page refuses to show it

The app doesn't verify merkle proofs or proof of work in v1, so a compromised server could show false
balances, or leave out or invent whole transactions and their block times. The checks above only make its answers agree with each other. See `docs/SECURITY.md`, accepted risk R2.

### 7. Lock on leaving

| Event | What happens |
|---|---|
| App inactive (app switcher, Control Center) | A cover hides the screen, including from the app switcher snapshot |
| App in background | Close server connection; remove key from Tor; `DisableNetwork 1`; drop vault contents and balances from app state; invalidate Face ID context |
| Back in foreground | Requires Face ID. Unlocking shows the saved balance and, if there are watched addresses, refreshes right away: this turns the network on, re-adds the key, and reconnects, retrying for up to about 4 minutes before showing a failure. If the last successful refresh was under 10 minutes ago and covers every watched address, it's shown as current and Tor stays off until you tap Refresh or open an address. With no addresses, Tor also stays off |

Tor keeps running because [one process can only start it once](https://github.com/iCepa/Tor.framework/blob/spm/Sources/CTor/TORThread.m).
`DisableNetwork` stops all its traffic while the app is backgrounded. It also starts with the network off, so nothing happens until an unlocked session asks.

Each connection attempt times out after 60 seconds. An attempt that took 20 seconds or more counts as stuck, so before the next attempt the app removes the key, turns Tor's network off and on (the same reset a lock and unlock causes), and gets a fresh copy of the service's info with `SIGNAL NEWNYM`. Without that last step, Tor can keep using stale details about how to reach a server that went quiet. Faster failures retry without a reset, because they usually pass quickly and a reset would bring back the moment right after Tor resumes. No new attempt starts after 3 minutes.

Hard Refresh, on the home screen at all times, abandons the current attempt right away and starts over: the same reset, plus `SIGNAL NEWNYM` for new circuits and a fresh copy of the service's info. Tor can't be restarted within one process, so this is as close to a restart as the app can get. It doesn't use `DROPGUARDS` or `DROPTIMEOUTS`, because Tor's docs warn that they make tracking easier over time.

A lock has to win against work already in progress. Tor commands run through a single queue, in an order fixed at the moment they're
queued, and anything that exposes something first checks that its session hasn't been locked. The app also asks iOS for background time, so the cleanup commands get to finish.

### 8. Input safety

- Third-party keyboards are disabled in this app, since they can log keystrokes.
- Fields turn off autocorrect and suggestions.
- The app doesn't write to the clipboard. The public key can be selected or sent with the share sheet, because it's public. Nothing else can be selected.
- Only mainnet addresses are accepted, with full checksum validation: P2PKH, P2SH, P2WPKH, P2WSH, and P2TR.

### 9. Demo mode

The welcome screen offers a demo, for people trying the app and for App Review, who can't reach a node.
It shows made-up balances and transactions (`DemoData.swift`) for public test-vector addresses.

- Every screen says it's sample data.
- It has no server address, so nothing can start Tor or connect. Refresh buttons and server settings are hidden.
- It never reads or writes the Keychain. Changes like a rename last only until the demo ends.
- Leaving the app or tapping Exit Demo ends it and returns to the welcome screen.
- It can only start when the phone has no real setup, so the two never mix.

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

The address page adds raw transactions and block headers, sent 20 at a time so a batch costs one round trip
over Tor. Replies are matched by ID. Each call has the connection to itself, so the page and a refresh can
share it, and a call that fails closes the connection, since its late replies could otherwise be mistaken
for the next call's.

```
-> {"id":6,...,"method":"blockchain.transaction.get","params":["<txid>"]}
-> {"id":7,...,"method":"blockchain.block.header","params":[800000]}
```

The page shows the newest 100 transactions of a larger history, plus up to 100 older ones fetched only to
price the coins those spend.

The scripthash is `SHA256(scriptPubKey)` with the bytes reversed. The server sees it, which reveals the address to
the server. That's fine, because the server is yours.

SOCKS5 with Tor's `ExtendedErrors` gives specific failures, so the app can show "this phone isn't authorized" (`0xF4`, `0xF5`) instead of
a generic timeout. After such a failure, Retry sends `SIGNAL NEWNYM`, which makes Tor discard its cached copy of the service
descriptor and fetch the one that includes the new key.

NEWNYM also clears client auth keys added without the `Permanent` flag, which is how this app adds its key (`hs_client_purge_state`
in Tor's source). So the app always sends NEWNYM first and adds the key after it. Tor delays a NEWNYM sent within 10 seconds of the
last one, and a delayed one would clear a key added in the meantime, so the app waits out that window before sending another.

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
