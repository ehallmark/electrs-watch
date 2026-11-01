# Vendored Tor.framework wrapper

| | |
|---|---|
| Upstream | https://github.com/iCepa/Tor.framework (MIT) |
| Commit | `d9c937991f5df872b07505b5d30790c8f3ea3863` (branch `spm`) |
| Release | `409.15.2`: Tor 0.4.9.15 |
| Binary | `tor-nolzma.xcframework.zip`, SHA-256 `0c3921c9fc58631428904f77d9c4afd49fa4c77ad608abf547bf7c409bb33b70` |

## Why this is vendored instead of added as a package

1. Upstream's manifest needs swift-tools 6.3. The development Mac has Xcode 26.3 (Swift 6.2.4).
2. It lets us patch the small Objective-C layer that starts Tor. The app only uses `TORThread`. `TORController` is not used:
   `Packages/WatchCore/Sources/WatchCore/TorControl.swift` replaces it. `TorCore` is only here because `TORThread.h` imports its headers.
3. It drops targets this app does not use (Arti, the lzma build).

## Local changes

- `Sources/CTorNoLzma/TORThread.m`: upstream declares `char *argv[argc]` and then writes
  `argv[argc] = NULL`, one element past the end of the array. Changed the size to `argc + 1`.
  Worth reporting upstream.
- `Package.swift`: rewritten as above.

## Trust

The Objective-C here is source. The Tor library itself is a prebuilt binary that SwiftPM verifies
by checksum. Upstream says these builds are not reproducible, so the checksum proves we got the
file we pinned, not that it matches the Tor source. See `docs/SECURITY.md`, accepted risk R1.

## Updating

1. Read https://github.com/iCepa/Tor.framework/releases and the Tor release notes.
2. Update the URL and checksum, re-copy `Sources/TorCore` and `Sources/CTor`, re-apply the patch if it
   is still needed, and update this file.
3. Run `scripts/test.sh` and `scripts/e2e/run.sh`.
