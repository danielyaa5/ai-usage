#!/bin/bash
# Builds and exports a local Mac App Store package with Xcode's configured account.
set -euo pipefail
cd "$(dirname "$0")/.."
test -f Local.xcconfig || { echo "Configure your team and bundle prefix in macos/Local.xcconfig." >&2; exit 1; }
out=build.noindex/Store
xcodegen generate --quiet
xcodebuild -scheme AIUsage -configuration Release -destination 'platform=macOS,arch=arm64' \
  -archivePath "$out/AIUsage.xcarchive" -derivedDataPath "$out/DerivedData" -allowProvisioningUpdates archive
xcodebuild -exportArchive -archivePath "$out/AIUsage.xcarchive" -exportPath "$out/export" \
  -exportOptionsPlist release/ExportOptions.plist -allowProvisioningUpdates
python3 release/verify-package.py "$out/export/AI Usage.pkg"

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [ -x "$LSREGISTER" ]; then
  "$LSREGISTER" -u "$out/AIUsage.xcarchive/Products/Applications/AI Usage.app" 2>/dev/null || true
  while IFS= read -r app_path; do
    [ -n "$app_path" ] && "$LSREGISTER" -u "$app_path" 2>/dev/null || true
  done < <(find "$out/DerivedData" -name "*.app" 2>/dev/null || true)
  if [ -d "/Applications/AI Usage.app" ]; then
    "$LSREGISTER" -f "/Applications/AI Usage.app" 2>/dev/null || true
  fi
fi
if command -v pluginkit >/dev/null 2>&1; then
  archived_plugin="$out/AIUsage.xcarchive/Products/Applications/AI Usage.app/Contents/PlugIns/AIUsageWidgets.appex"
  if [ -e "$archived_plugin" ]; then
    pluginkit -r "$archived_plugin" 2>/dev/null || true
  fi
fi

