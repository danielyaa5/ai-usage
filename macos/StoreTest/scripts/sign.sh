#!/bin/bash
# Sign the two test builds in a kit folder made by build.sh (see ../README.md), on the Mac that has
# your Apple Development certificate:
#
#   ./sign.sh        # unsigned-1.zip, unsigned-2.zip -> signed-1.zip, signed-2.zip
#
# Uses SIGN_IDENTITY (a certificate name or SHA-1) and DEVELOPMENT_TEAM when set, and otherwise your
# only Apple Development certificate. Run it in your login session (Terminal, or a LaunchAgent in
# gui/<uid>): over SSH, codesign usually can't use the login keychain (errSecInternalComponent).
#
# The Codex helper gets exactly the two entitlements a helper tool in a sandboxed app may have,
# app-sandbox and inherit. Build 1 signs it without the hardened runtime and build 2 with it, so the
# update run also shows whether Codex works hardened: OpenAI signs it with allow-jit and
# allow-unsigned-executable-memory, which a hardened helper here doesn't get.
set -euo pipefail
KIT=$(cd "$(dirname "$0")" && pwd)
cd "$KIT"
APP_NAME="AI Usage Store Test.app"
HELPER_NAME=codex-app-server

cert_team() {  # cert_team SHA1 -> the team (OU) of that certificate in your keychains
  security find-certificate -a -Z -p | awk -v hash="$1" '
    /^SHA-1 hash:/ { keep = ($3 == hash) }
    keep && /BEGIN CERTIFICATE/ { printing = 1 }
    printing { print }
    /END CERTIFICATE/ { if (printing) exit; printing = 0 }' |
    openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU *= *\([A-Z0-9]*\).*/\1/p'
}

IDENTITY=${SIGN_IDENTITY:-}
TEAM=${DEVELOPMENT_TEAM:-}
if [ -z "$IDENTITY" ]; then
  for hash in $(security find-identity -v -p codesigning | awk '/"Apple Development: / { print $2 }'); do
    team=$(cert_team "$hash")
    if [ -z "$TEAM" ] || [ "$team" = "$TEAM" ]; then
      IDENTITY=$hash
      TEAM=$team
      break
    fi
  done
fi
if [ -z "$IDENTITY" ]; then
  echo "No Apple Development certificate found. These can sign code:" >&2
  security find-identity -v -p codesigning >&2
  exit 1
fi
[ -n "$TEAM" ] || TEAM=$(cert_team "$IDENTITY")
case "$TEAM" in
  [A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]) ;;
  *) echo "Couldn't tell the certificate's team ID (got '$TEAM'); set DEVELOPMENT_TEAM." >&2; exit 1 ;;
esac

for n in 1 2; do
  [ -f "unsigned-$n.zip" ] || { echo "Missing unsigned-$n.zip; run build.sh first." >&2; exit 1; }
  mkdir -p "$KIT/work.noindex"   # Spotlight and LaunchServices skip .noindex folders
  WORK=$(mktemp -d "$KIT/work.noindex/sign.XXXXXX")
  ditto -x -k "unsigned-$n.zip" "$WORK"
  APP="$WORK/$APP_NAME"
  HELPER="$APP/Contents/MacOS/$HELPER_NAME"
  WIDGET="$APP/Contents/PlugIns/StoreTestWidget.appex"
  [ -x "$HELPER" ] || { echo "No $HELPER_NAME in build $n." >&2; exit 1; }
  BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")
  GROUP="$TEAM.$BUNDLE_ID"
  sed "s/\$(AI_USAGE_APP_GROUP)/$GROUP/" entitlements/StoreTest.entitlements > "$WORK/app.entitlements"
  sed "s/\$(AI_USAGE_APP_GROUP)/$GROUP/" entitlements/StoreTestWidget.entitlements > "$WORK/widget.entitlements"

  if [ "$n" = 1 ]; then HELPER_OPTIONS=""; else HELPER_OPTIONS="--options runtime"; fi
  # Inside out: the helper and the extension first, then the app that seals them.
  # shellcheck disable=SC2086
  codesign --force $HELPER_OPTIONS --timestamp=none --sign "$IDENTITY" --identifier "$BUNDLE_ID.$HELPER_NAME" \
    --entitlements entitlements/codex.entitlements "$HELPER"
  codesign --force --options runtime --timestamp=none --sign "$IDENTITY" \
    --entitlements "$WORK/widget.entitlements" "$WIDGET"
  codesign --force --options runtime --timestamp=none --sign "$IDENTITY" \
    --entitlements "$WORK/app.entitlements" "$APP"
  codesign --verify --deep --strict "$APP"

  echo "Build $n ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")), App Group $GROUP:"
  codesign -d --verbose=1 "$HELPER" 2>&1 | grep -E '^(Identifier|CodeDirectory|TeamIdentifier)=' | sed 's/^/  helper: /'
  codesign -d --entitlements - --xml "$HELPER" 2>/dev/null | tr -d '\n\t' | sed 's/^/  helper entitlements: /'
  echo
  rm -f "signed-$n.zip"
  ditto -c -k --keepParent "$APP" "signed-$n.zip"
  rm -rf "$WORK"
done
echo "Signed: $KIT/signed-1.zip and $KIT/signed-2.zip"
