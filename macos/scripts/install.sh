#!/bin/bash
# Install the signed build in /Applications, register its widgets and start it in the background.
#
#   macos/scripts/install.sh [path/to/AI Usage.app]
#
# It replaces the whole bundle (copying over an old one can leave the widget's signature broken),
# keeps a single copy registered with LaunchServices, and refuses to replace a different app.
# If the widget gallery still shows an old version afterwards: killall chronod NotificationCenter
set -euo pipefail
cd "$(dirname "$0")/.."

SOURCE=${1:-"build.noindex/AI Usage.app"}
TARGET="/Applications/AI Usage.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

[ -d "$SOURCE" ] || { echo "No app at $SOURCE; run scripts/build.sh first." >&2; exit 1; }
codesign --verify --deep --strict "$SOURCE"
ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE/Contents/Info.plist")
if [ -d "$TARGET" ]; then
  OLD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TARGET/Contents/Info.plist" 2>/dev/null || true)
  if [ "$OLD" != "$ID" ]; then
    echo "$TARGET is a different app ($OLD); not replacing it." >&2
    exit 1
  fi
fi

pkill -x "AI Usage" 2>/dev/null && sleep 1 || true
STAGE=$(mktemp -d /tmp/ai-usage-install.XXXXXX)
ditto "$SOURCE" "$STAGE/AI Usage.app"
rm -rf "$TARGET"
ditto "$STAGE/AI Usage.app" "$TARGET"
rm -rf "$STAGE"
touch "$TARGET"

"$LSREGISTER" -f "$TARGET"
"$LSREGISTER" -u "$SOURCE" 2>/dev/null || true
pluginkit -a "$TARGET/Contents/PlugIns/AIUsageWidgets.appex" || true
# Give macOS a few seconds to take in the new build before it reads the network: once, after a read
# within a second of the install, the app and its widgets were refused local network access for about
# ten minutes.
sleep 5
# A widget extension still running from the old build keeps drawing with it until it quits.
pkill -x AIUsageWidgets 2>/dev/null || true
open -g -a "$TARGET"

echo "Installed $TARGET"
pluginkit -m -v -i "$ID.Widgets" || echo "The widget extension isn't registered yet; give it a few seconds."
