#!/usr/bin/env bash
# Full test: real app + real Tor network + a temporary, client-authorized onion service + mock electrs.
# Only runs Tor for the length of the test and only uses public test-vector addresses.
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
TOR_BIN="${TOR_BIN:-$(brew --prefix)/bin/tor}"
[ -x "$TOR_BIN" ] || { echo "Missing tor. Run: brew install tor" >&2; exit 1; }

SIM_NAME="ElectrsWatch-E2E"
BUNDLE_ID=com.ehallmark.electrswatch
MOCK_PORT=45001
work="$(mktemp -d /tmp/ew-e2e.XXXXXX)"
chmod 700 "$work"
results="$repo/build/e2e"
rm -rf "$results"; mkdir -p "$results"
tor_pid="" mock_pid="" match_pid="" test_pid=""

cleanup() {
  # A frozen process wouldn't act on the kill below.
  [ -n "$tor_pid" ] && kill -CONT "$tor_pid" 2>/dev/null || true
  for pid in "$test_pid" "$match_pid" "$mock_pid" "$tor_pid"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done
  cp "$work/tor.log" "$results/service-tor.log" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 1' INT TERM
fail() { echo "FAIL: $1" >&2; exit 1; }
wait_for() { # file, seconds
  local waited=0
  until [ -s "$work/$1" ]; do
    kill -0 "$test_pid" 2>/dev/null || fail "UI test ended before $1"
    sleep 2; waited=$((waited + 2))
    [ "$waited" -lt "$2" ] || fail "timed out waiting for $1"
  done
}

echo "==> Simulator"
runtime="$(xcrun simctl list runtimes -j | python3 -c 'import json,sys; print([r["identifier"] for r in json.load(sys.stdin)["runtimes"] if r["platform"]=="iOS" and r["isAvailable"]][-1])')"
device="$(xcrun simctl list devices -j | python3 -c "
import json,sys
for ds in json.load(sys.stdin)['devices'].values():
    for d in ds:
        if d['name']=='$SIM_NAME' and d['isAvailable']: print(d['udid']); raise SystemExit
")"
[ -n "$device" ] || device="$(xcrun simctl create "$SIM_NAME" "iPhone 17 Pro" "$runtime")"
xcrun simctl bootstatus "$device" -b >/dev/null
xcrun simctl uninstall "$device" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl keychain "$device" reset
sim() { xcrun simctl spawn "$device" "$@"; }
sim notifyutil -s com.apple.BiometricKit.enrollmentChanged 1
sim notifyutil -p com.apple.BiometricKit.enrollmentChanged

echo "==> Mock electrs and onion service"
python3 "$repo/scripts/e2e/mock_electrs.py" "$MOCK_PORT" "$work/methods.log" &
mock_pid=$!
install -d -m 700 "$work/tor" "$work/tor/hs" "$work/tor/hs/authorized_clients"
# A random stranger's key, so the service requires client auth from the start.
python3 -c 'import base64,os; print("descriptor:x25519:"+base64.b32encode(os.urandom(32)).decode().rstrip("="))' > "$work/tor/hs/authorized_clients/stranger.auth"
cat > "$work/torrc" <<EOF
DataDirectory $work/tor
PidFile $work/tor.pid
SocksPort 0
ControlPort 0
Log notice file $work/tor.log
HiddenServiceDir $work/tor/hs
HiddenServicePort 50001 127.0.0.1:$MOCK_PORT
EOF
"$TOR_BIN" -f "$work/torrc" >/dev/null &
tor_pid=$!
for _ in $(seq 60); do [ -s "$work/tor/hs/hostname" ] && break; sleep 1; done
[ -s "$work/tor/hs/hostname" ] || fail "onion service did not start"
onion="$(cat "$work/tor/hs/hostname")"
cp "$work/tor/hs/hostname" "$work/onion.txt"
echo "    waiting for the service to publish"
for _ in $(seq 240); do grep -q 'Bootstrapped 100%' "$work/tor.log" && break; sleep 1; done
grep -q 'Bootstrapped 100%' "$work/tor.log" || fail "service Tor did not bootstrap"

echo "==> Face ID simulation loop"
( while true; do sim notifyutil -p com.apple.BiometricKit_Sim.pearl.match >/dev/null 2>&1 || true; sleep 2; done ) &
match_pid=$!

echo "==> Building and starting the UI test"
TEST_RUNNER_EW_E2E_DIR="$work" xcodebuild test \
  -project "$repo/ElectrsWatch.xcodeproj" -scheme ElectrsWatch \
  -destination "platform=iOS Simulator,id=$device" \
  -derivedDataPath "$repo/build/dd" -resultBundlePath "$results/result.xcresult" \
  -jobs 4 -parallel-testing-enabled NO > "$results/xcodebuild.log" 2>&1 &
test_pid=$!

wait_for refused.flag 900
echo "PASS: refused before the phone's key was authorized"
wait_for pubkey.txt 30
pubkey="$(cat "$work/pubkey.txt")"
[[ "$pubkey" =~ ^descriptor:x25519:[A-Z2-7]{52}$ ]] || fail "bad public key format"
echo "$pubkey" > "$work/tor/hs/authorized_clients/phone.auth"
chmod 600 "$work/tor/hs/authorized_clients/phone.auth"
kill -HUP "$(cat "$work/tor.pid")"
echo 1 > "$work/authorized.flag"
echo "    key authorized, waiting for connection"

wait_for connected.flag 900
echo "PASS: connected over Tor with correct values"
xcrun simctl io "$device" screenshot "$results/home.png" >/dev/null 2>&1 || true
app_pid="$(pgrep -nx ElectrsWatch || true)"
[ -n "$app_pid" ] || fail "app process not found"

if listeners="$(lsof -nP -a -p "$app_pid" -iTCP -sTCP:LISTEN 2>/dev/null)" && [ -n "$listeners" ]; then
  fail "app has TCP listeners: $listeners"
fi
echo "PASS: no TCP listeners in the app process"

container="$(xcrun simctl get_app_container "$device" "$BUNDLE_ID" data)"
tordir="$container/Library/Application Support/tor"
[ -f "$tordir/cached-microdesc-consensus" ] || [ -f "$tordir/state" ] || fail "expected Tor files not found, so the disk checks below prove nothing"
service_id="${onion%.onion}"
if grep -rlq "$service_id" "$container" 2>/dev/null; then
  fail "onion address found in app files: $(grep -rl "$service_id" "$container" | head -3)"
fi
find "$container" -name '*.auth_private' | grep -q . && fail "client auth key file on disk"
# The saved balance has just been written, and it must only be in the Keychain.
if grep -rlq '1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa' "$container" 2>/dev/null; then
  fail "watched address found in app files: $(grep -rl '1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa' "$container" | head -3)"
fi
echo "PASS: no onion address, watched address or key files in the app container"
echo 1 > "$work/inspected.flag"

wait_for resumed.flag 600
echo "PASS: locked on background, showed the saved balance after unlock, refreshed on open"
cp "$work/saved.png" "$results/saved.png" 2>/dev/null || true

echo "==> Freezing the service so the next open stalls"
kill -STOP "$tor_pid"
echo 1 > "$work/service-frozen.flag"
wait_for stall-started.flag 120
# Longer than one attempt's timeout, so at least one attempt stalls and fails.
sleep 75
kill -CONT "$tor_pid"
echo 1 > "$work/service-thawed.flag"
wait_for recovered.flag 420
echo "PASS: recovered from a stall by resetting Tor, with no tap, and logged it"
cp "$work/log.png" "$results/log.png" 2>/dev/null || true

wait "$test_pid" && test_status=0 || test_status=$?
test_pid=""
[ "$test_status" -eq 0 ] || fail "UI test failed, see $results/xcodebuild.log"
echo "PASS: UI test"

unexpected="$(awk '{print $1}' "$work/methods.log" | sort -u | grep -vxE 'server\.version|blockchain\.headers\.subscribe|blockchain\.scripthash\.subscribe|blockchain\.scripthash\.get_balance|blockchain\.scripthash\.get_history' || true)"
[ -z "$unexpected" ] || fail "app sent other methods: $unexpected"
echo "PASS: only allowlisted Electrum methods ($(wc -l < "$work/methods.log" | tr -d ' ') calls)"
echo "ALL E2E CHECKS PASSED"
