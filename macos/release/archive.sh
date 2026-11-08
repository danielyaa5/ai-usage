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
