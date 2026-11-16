#!/bin/bash
# Builds a Developer ID copy of the Mac App Store app for direct download, has Apple notarize it
# with Xcode's configured account, and zips the stapled app.
#
#   macos/release/archive-direct.sh                  # -> macos/build.noindex/Direct/AI-Usage-<version>-<build>.zip
#   BUILD_NUMBER=16 macos/release/archive-direct.sh  # override the build number for this copy only
#   OUT=/some/folder macos/release/archive-direct.sh # put the archive, export and zip elsewhere
#
# The app, widget, helper, entitlements, bundle ID and App Group are the same as the Store build;
# only the export method differs. Xcode signs with a cloud-managed Developer ID certificate, so the
# Xcode account needs access to one for the team in Local.xcconfig. It does not publish anything.
set -euo pipefail
cd "$(dirname "$0")/.."
test -f Local.xcconfig || { echo "Configure your team and bundle prefix in macos/Local.xcconfig." >&2; exit 1; }
mkdir -p "${OUT:-build.noindex/Direct}"
out=$(cd "${OUT:-build.noindex/Direct}" && pwd)
archive="$out/AIUsage.xcarchive"
overrides=()
[ -n "${BUILD_NUMBER:-}" ] && overrides=("CURRENT_PROJECT_VERSION=$BUILD_NUMBER")

rm -rf "$archive" "$out/upload" "$out/export"
xcodegen generate --quiet
xcodebuild -scheme AIUsage -configuration Release -destination 'platform=macOS,arch=arm64' \
  -archivePath "$archive" -derivedDataPath "$out/DerivedData" -allowProvisioningUpdates \
  ${overrides[@]+"${overrides[@]}"} archive
xcodebuild -exportArchive -archivePath "$archive" -exportPath "$out/upload" \
  -exportOptionsPlist release/ExportOptions-direct.plist -allowProvisioningUpdates

# The export uploads the app to Apple's notary service. Wait for it, then export the stapled app.
for attempt in $(seq 1 80); do
  if xcodebuild -exportNotarizedApp -archivePath "$archive" -exportPath "$out/export" > "$out/notarized.log" 2>&1; then
    break
  fi
  if [ "$attempt" = 80 ]; then cat "$out/notarized.log" >&2; exit 1; fi
  sleep 30
done
app="$out/export/AI Usage.app"
python3 release/verify-direct.py "$app"

info="$app/Contents/Info.plist"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info")
zip="$out/AI-Usage-$version-$build.zip"
rm -f "$zip" "$zip.sha256"
ditto -c -k --keepParent "$app" "$zip"
python3 release/verify-direct.py --zip "$zip"
(cd "$out" && shasum -a 256 "$(basename "$zip")" > "$(basename "$zip").sha256")

# Keep the build copies out of LaunchServices and the widget gallery.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
while IFS= read -r built; do
  "$LSREGISTER" -u "$built" 2>/dev/null || true
  [ -e "$built/Contents/PlugIns/AIUsageWidgets.appex" ] && pluginkit -r "$built/Contents/PlugIns/AIUsageWidgets.appex" 2>/dev/null || true
done < <(find "$out" -name "*.app" -prune 2>/dev/null)
echo "Notarized download: $zip"
cat "$zip.sha256"
