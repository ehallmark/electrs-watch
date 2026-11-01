#!/usr/bin/env bash
# Usage: scripts/testflight-build.sh [--upload]
# Builds and checks an App Store Connect signed copy of the app. Nothing leaves this
# machine without --upload.
#
# With PROFILE_NAME set (GitHub Actions): signs with that installed profile and an
# Apple Distribution certificate in the keychain.
# Without it (local dry run): signs through the Xcode account on this Mac.
#
# Exits 3 after a successful build if the certificate or profile needs renewing soon,
# so GitHub sends a failure email while there's still time to act.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

upload=no
case "${1:-}" in
  "") ;;
  --upload) upload=yes ;;
  *) echo "Usage: scripts/testflight-build.sh [--upload]" >&2; exit 2 ;;
esac

bundle_id=com.ehallmark.electrswatch
renew_within_days=45
signing=Config/Signing.local.xcconfig

team="${APPLE_TEAM_ID:-}"
if [ -z "$team" ]; then
  team="$(sed -nE 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*([A-Z0-9]{10})[[:space:]]*$/\1/p' "$signing" 2>/dev/null | head -1 || true)"
fi
[ -n "$team" ] || { echo "Set APPLE_TEAM_ID or DEVELOPMENT_TEAM in $signing." >&2; exit 1; }

profile_name="${PROFILE_NAME:-}"
if [ "$upload" = yes ]; then
  [ -n "$profile_name" ] || { echo "--upload needs PROFILE_NAME. Uploads only run from GitHub Actions." >&2; exit 1; }
  [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ] || { echo "--upload needs ASC_KEY_ID and ASC_ISSUER_ID." >&2; exit 1; }
fi

# Each upload needs a higher build number, and the time always increases.
build_number="$(date -u +%Y%m%d%H%M)"
out="build/testflight/$build_number"
mkdir -p "$out"
archive="$out/ElectrsWatch.xcarchive"
options="$out/ExportOptions.plist"

if [ -n "$profile_name" ]; then
  signing_options="<key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Apple Distribution</string>
  <key>provisioningProfiles</key><dict><key>$bundle_id</key><string>$profile_name</string></dict>"
  export_flags=()
else
  signing_options="<key>signingStyle</key><string>automatic</string>"
  export_flags=(-allowProvisioningUpdates)
fi

cat > "$options" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>export</string>
  <key>teamID</key><string>$team</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>uploadSymbols</key><false/>
  $signing_options
</dict>
</plist>
EOF

echo "==> Archiving build $build_number with $(xcodebuild -version | head -1)"
# Unsigned here: only the export step below needs signing material.
xcodebuild -project ElectrsWatch.xcodeproj -scheme ElectrsWatch -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$archive" \
  CODE_SIGNING_ALLOWED=NO CURRENT_PROJECT_VERSION="$build_number" archive -quiet

echo "==> Signing"
xcodebuild -exportArchive -archivePath "$archive" -exportPath "$out" \
  -exportOptionsPlist "$options" ${export_flags[@]+"${export_flags[@]}"} -quiet

echo "==> Checking the signed build"
unpacked="$out/unpacked"
mkdir -p "$unpacked"
ditto -x -k "$out/ElectrsWatch.ipa" "$unpacked"
app="$unpacked/Payload/ElectrsWatch.app"
codesign --verify --deep --strict "$app"

profile="$out/profile.plist"
security cms -D -i "$app/embedded.mobileprovision" > "$profile"
read_profile() { /usr/libexec/PlistBuddy -c "Print :$1" "$profile" 2>/dev/null || true; }
fail() { echo "FAIL: $1" >&2; exit 1; }

[ "$(read_profile Entitlements:get-task-allow)" = "false" ] || fail "a debugger could attach to this build."
[ -z "$(read_profile ProvisionedDevices:0)" ] || fail "this profile is for specific devices, not App Store Connect."
[ "$(read_profile Entitlements:com.apple.developer.team-identifier)" = "$team" ] || fail "the profile belongs to a different team."
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")" = "$bundle_id" ] || fail "wrong bundle ID."
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Info.plist")" = "$build_number" ] || fail "wrong build number."
# The embedded Tor encrypts traffic itself, so the build must not claim otherwise.
[ "$(/usr/libexec/PlistBuddy -c 'Print :ITSAppUsesNonExemptEncryption' "$app/Info.plist" 2>/dev/null)" = "true" ] || fail "the encryption declaration is missing."

renew=no
profile_end="$(plutil -extract ExpirationDate raw -o - "$profile")"
profile_end_epoch="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$profile_end" +%s)"
if [ "$profile_end_epoch" -lt "$(( $(date +%s) + renew_within_days * 86400 ))" ]; then renew=yes; fi
certificate="$out/certificate.der"
/usr/libexec/PlistBuddy -c 'Print :DeveloperCertificates:0' "$profile" > "$certificate"
if ! openssl x509 -inform der -in "$certificate" -noout -checkend "$(( renew_within_days * 86400 ))" >/dev/null; then renew=yes; fi

echo "PASS  signature valid; debugger attach disabled; App Store Connect profile"
echo "INFO  build number: $build_number"
echo "INFO  profile: $(read_profile Name), expires $profile_end"
echo "INFO  certificate: $(openssl x509 -inform der -in "$certificate" -noout -subject -enddate | tr '\n' ' ')"

if [ "$upload" = yes ]; then
  echo "==> Uploading to App Store Connect"
  xcrun altool --upload-app --type ios --file "$out/ElectrsWatch.ipa" \
    --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
  echo "PASS  uploaded build $build_number"
else
  echo "INFO  dry run, nothing uploaded: $out/ElectrsWatch.ipa"
fi

if [ "$renew" = yes ]; then
  echo "RENEW: the certificate or profile expires within $renew_within_days days. See docs/RELEASING.md." >&2
  exit 3
fi
