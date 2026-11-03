#!/usr/bin/env bash
# Unit tests, plus checks that the code keeps its security boundaries.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"

status=0
# No connection path outside the Tor Unix socket, no storage outside the Keychain, no logging.
banned='URLSession|URLRequest|NWConnection|NWListener|NWEndpoint|CFStream|CFSocket|AF_INET|inet_pton|getaddrinfo|gethostbyname|WKWebView|SFSafari|UserDefaults|AppStorage|UIPasteboard|NSLog|os_log|Logger\(|[^a-zA-Z.]print\(|openURL|CoreData|SwiftData'
# One exception: the light or dark choice, which the lock screen needs before Face ID. Only lines
# that name its key are allowed, so nothing else can start using UserDefaults unnoticed.
if grep -rnE "$banned" App Packages/WatchCore/Sources | grep -v 'AppStorage(Appearance.storageKey)'; then
  echo "FAIL: banned API found above" >&2; status=1
fi
if grep -rniE 'broadcast|private_key|sign_?tx|seed|mnemonic|xprv' Packages/WatchCore/Sources App | grep -vE 'privateKey|seed phrase'; then
  echo "FAIL: wallet or spending code found above" >&2; status=1
fi
[ "$status" -eq 0 ] && echo "PASS: boundary checks"

(cd Packages/WatchCore && swift test -j 4 2>&1 | grep -E '✘|Test run with|error:' )
exit "$status"
