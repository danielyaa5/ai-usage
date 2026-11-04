#!/bin/bash
# Sign the two test builds in a kit folder made by build.sh (see ../README.md), on the Mac that has
# your Apple Development certificate:
#
#   ./sign.sh        # unsigned-1.zip, unsigned-2.zip -> signed-1.zip, signed-2.zip
#
# run.sh calls it when the builds haven't been signed yet. It uses SIGN_IDENTITY (a certificate name
# or SHA-1) or DEVELOPMENT_TEAM when set, in the environment or in a local.env file next to it, and
# otherwise your only Apple Development certificate. Run it in your login session (Terminal, or a
# LaunchAgent in gui/<uid>): over SSH, codesign usually can't use the login keychain
# (errSecInternalComponent).
#
# The Codex helper gets exactly the two entitlements a helper tool in a sandboxed app may have,
# app-sandbox and inherit. Build 1 signs it without the hardened runtime and build 2 with it, so the
# update run also shows whether Codex works hardened: OpenAI signs it with allow-jit and
# allow-unsigned-executable-memory, which a hardened helper here doesn't get.
set -euo pipefail
KIT=$(cd "$(dirname "$0")" && pwd)
cd "$KIT"
# This Mac's own settings, kept out of the repo.
if [ -f "$KIT/local.env" ]; then . "$KIT/local.env"; fi
APP_NAME="AI Usage Store Test.app"
HELPER_NAME=codex-app-server

cert_team() {  # cert_team SHA1 -> the team (OU) of that certificate in your keychains, or nothing
  # awk reads to the end rather than exiting at the match: an early exit leaves security writing to a
  # closed pipe, and its SIGPIPE ends the whole script through pipefail and set -e, with no message.
  security find-certificate -a -Z -p | awk -v hash="$1" '
    /^SHA-1 hash:/ { keep = (!done && $3 == hash) }
    keep && /BEGIN CERTIFICATE/ { printing = 1 }
    printing { print }
    /END CERTIFICATE/ { if (printing) done = 1; printing = 0 }' |
    openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU *= *\([A-Z0-9]*\).*/\1/p' || true
}

IDENTITY=${SIGN_IDENTITY:-}
TEAM=${DEVELOPMENT_TEAM:-}
if [ -z "$IDENTITY" ]; then
  FOUND_TEAM=""
  TEAMS=""
  for hash in $(security find-identity -v -p codesigning | awk '/"Apple Development: / { print $2 }'); do
    team=$(cert_team "$hash")
    if [ -z "$TEAM" ] || [ "$team" = "$TEAM" ]; then
      if [ -z "$IDENTITY" ]; then
        IDENTITY=$hash
        FOUND_TEAM=$team
      fi
      case " $TEAMS " in *" $team "*) ;; *) TEAMS="$TEAMS $team" ;; esac
    fi
  done
  # Certificates from several teams: don't guess whose to sign with.
  if [ -z "$TEAM" ] && [ "$(printf '%s' "$TEAMS" | wc -w | tr -d ' ')" -gt 1 ]; then
    echo "Apple Development certificates from more than one team can sign here. Put the one to use in" >&2
    echo "$KIT/local.env as DEVELOPMENT_TEAM=<team ID>. These are the certificates:" >&2
    security find-identity -v -p codesigning | grep '"Apple Development: ' >&2
    exit 1
  fi
  TEAM=${TEAM:-$FOUND_TEAM}
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
  ditto --noqtn -x -k "unsigned-$n.zip" "$WORK"
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
  # CodeDirectory's flags show the runtime flag (build 2) or 0x0 (build 1).
  codesign -d --verbose=1 "$HELPER" 2>&1 | grep -E '^(Identifier=|CodeDirectory |TeamIdentifier=|Runtime Version=)' |
    sed 's/^/  helper: /' || true
  codesign -d --entitlements - --xml "$HELPER" 2>/dev/null | tr -d '\n\t' | sed 's/^/  helper entitlements: /'
  echo
  rm -f "signed-$n.zip"
  ditto -c -k --keepParent "$APP" "signed-$n.zip"
  rm -rf "$WORK"
done
echo "Signed: $KIT/signed-1.zip and $KIT/signed-2.zip"
