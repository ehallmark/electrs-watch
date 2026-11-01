# Plan

| # | Milestone | Done when | Status |
|---|---|---|---|
| M1 | Design and repo | Docs reviewed; private GitHub repo exists | Done |
| M2 | Core logic (`WatchCore`) | Unit tests pass, including published BIP test vectors and hostile server replies | Done: 49 tests |
| M3 | App + embedded Tor | Builds and boots in the simulator, Tor bootstraps | Done |
| M4 | Simulator E2E | Over the real Tor network: refused without key, works with key, correct balances, no non-allowlisted methods | Done on 2026-11-01, against a mock server |
| M5 | Real iPhone | Release Testing build installed; Face ID, background lock, file protection, keyboard block all verified | Needs your iPhone |
| M6 | Real node | Connects to real electrs after sync; balance matches Electrum on the Mac | Needs node sync |
| M7 | Optional hardening | Header PoW checks; build Tor from source; audit script watches the new onion | Later |

## What the simulator can't prove

The simulator is good for logic, UI, and real Tor connections. It doesn't enforce iOS's file encryption or match real Face ID hardware, and it
runs on the Mac's kernel. So everything marked "Device test" in `SECURITY.md` stays open until M5, whatever the simulator shows.

## Test approach

| Layer | Tool | Covers |
|---|---|---|
| Unit | `swift test` | Addresses, scripthash, SOCKS, Electrum framing, hostile input, amounts |
| Boundary | `scripts/test.sh` grep | No `URLSession`, `NWConnection`, IP socket code, or logging of secrets |
| E2E | XCUITest + `scripts/e2e/run.sh` | The real app and real Tor against a temporary onion service with a mock electrs |
| Real | Manual | M5 and M6 checklists |

The E2E mock server computes script hashes with its own Python code, so a mistake in the Swift implementation can't hide in both sides.

## M5 checklist (real iPhone)

- [ ] `scripts/release-build.sh --install "<device>"` passes its checks, and its expiry date is about a year away
- [ ] With Developer Mode turned off and the phone restarted, the app still opens
- [ ] First launch asks for Face ID when saving and when reopening
- [ ] A failed Face ID match says to try again and doesn't offer to erase
- [ ] Enrolling a new face makes the data unreadable and offers a clean reset
- [ ] With Settings open, the app switcher shows the cover
- [ ] Locking the phone with the app open causes no crash (Tor's files use `completeFileProtection`)
- [ ] Backgrounding shows the cover, and reopening requires Face ID
- [ ] Third-party keyboard doesn't appear
- [ ] `tor` directory has `NSFileProtectionComplete` (check via a debug build)
- [ ] Encrypted Finder backup doesn't contain the Keychain item
- [ ] Airplane mode gives a clear error, with no crash
- [ ] Bootstrap time on cellular is acceptable

## M6 checklist (real node)

- [ ] Follow `NODE-SETUP.md`
- [ ] Without authorization, the app shows "not authorized"
- [ ] Balance and tip height match Electrum on the Mac over the SSH tunnel
- [ ] `node-audit` reports 0 failed after the new baseline
- [ ] Removing the client file stops access, after adding a replacement or disabling the service
