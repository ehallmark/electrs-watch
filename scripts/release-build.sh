#!/usr/bin/env bash
# Usage: scripts/release-build.sh [--install "iPhone name or device id"]
# Builds a Release Testing (Ad Hoc) copy of the app, signed for your registered
# devices, and refuses to pass a build that a debugger could attach to.
# Needs a paid Apple Developer Program team in Config/Signing.local.xcconfig.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

device=""
case "${1:-}" in
  "") ;;
  --install)
    device="${2:-}"
    [ -n "$device" ] || { echo "--install needs a device name or id. See: xcrun devicectl list devices" >&2; exit 2; }
    ;;
  *) echo "Usage: scripts/release-build.sh [--install \"iPhone name or device id\"]" >&2; exit 2 ;;
esac

signing=Config/Signing.local.xcconfig
team="$(sed -nE 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*([A-Z0-9]{10})[[:space:]]*$/\1/p' "$signing" 2>/dev/null | head -1 || true)"
if [ -z "$team" ]; then
  echo "Put your 10-character paid Team ID in $signing:" >&2
  echo "  DEVELOPMENT_TEAM = YOUR_TEAM_ID" >&2
  echo "It is listed under Membership details at https://developer.apple.com/account" >&2
  exit 1
fi

out="build/release/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$out"
archive="$out/ElectrsWatch.xcarchive"
options="$out/ExportOptions.plist"

cat > "$options" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>release-testing</string>
  <key>teamID</key><string>$team</string>
  <key>signingStyle</key><string>automatic</string>
  <key>thinning</key><string>&lt;none&gt;</string>
</dict>
</plist>
EOF

echo "==> Archiving"
xcodebuild -project ElectrsWatch.xcodeproj -scheme ElectrsWatch -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$archive" \
  -allowProvisioningUpdates archive -quiet

echo "==> Exporting"
xcodebuild -exportArchive -archivePath "$archive" -exportPath "$out" \
  -exportOptionsPlist "$options" -allowProvisioningUpdates -quiet

echo "==> Checking the signed build"
payload="$out/unpacked"
mkdir -p "$payload"
ditto -x -k "$out/ElectrsWatch.ipa" "$payload"
app="$payload/Payload/ElectrsWatch.app"
codesign --verify --deep --strict "$app"

profile="$out/profile.plist"
security cms -D -i "$app/embedded.mobileprovision" > "$profile"
read_profile() { /usr/libexec/PlistBuddy -c "Print :$1" "$profile" 2>/dev/null || true; }

debuggable="$(read_profile Entitlements:get-task-allow)"
if [ "$debuggable" != "false" ]; then
  echo "FAIL: get-task-allow is '$debuggable', so this is not a release-signed build." >&2
  exit 1
fi
if [ -z "$(read_profile ProvisionedDevices:0)" ]; then
  echo "FAIL: the profile lists no devices, so this is not a Release Testing build." >&2
  exit 1
fi
if [ "$(read_profile Entitlements:com.apple.developer.team-identifier)" != "$team" ]; then
  echo "FAIL: the profile belongs to a different team than $team." >&2
  exit 1
fi

echo "PASS  signature valid; debugger attach disabled"
echo "INFO  team: $team"
echo "INFO  profile: $(read_profile Name)"
echo "INFO  expires: $(read_profile ExpirationDate)"
echo "INFO  build: $out/ElectrsWatch.ipa"

if [ -n "$device" ]; then
  echo "==> Installing on $device"
  xcrun devicectl device install app --device "$device" "$app"
fi
