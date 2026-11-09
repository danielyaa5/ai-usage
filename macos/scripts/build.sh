#!/bin/bash
# Build "AI Usage.app" with its widgets and sign it with your Apple Development certificate.
#
#   macos/scripts/build.sh        # -> macos/build.noindex/AI Usage.app
#   macos/scripts/build.sh --fresh-install   # Separate first-run app, settings, widgets and links
#   macos/scripts/build.sh --setup-test     # Existing private test app with automatic Claude quota
#   macos/scripts/build.sh --claude-fresh-test  # Isolated first launch and Claude sign-in
#
# Reads DEVELOPMENT_TEAM and AI_USAGE_BUNDLE_PREFIX from the environment or macos/Local.xcconfig,
# and SIGN_IDENTITY (a certificate name or SHA-1) when the team has more than one certificate.
# Needs Xcode and XcodeGen (brew install xcodegen).
#
# Xcode builds it unsigned and this script signs the widget extension, then the app, with the
# entitlements filled in. That needs no provisioning profile: a team-prefixed App Group, the sandbox
# and outgoing connections are all open to a development certificate on macOS.
#
# Over SSH, codesign can fail with errSecInternalComponent because the login keychain is locked to
# that session. Run it in a Terminal on the Mac, or from a one-off LaunchAgent in your GUI session.
set -euo pipefail
cd "$(dirname "$0")/.."

setting() {  # setting NAME -> the environment's value, else Local.xcconfig's
  local value="${!1:-}"
  if [ -z "$value" ] && [ -f Local.xcconfig ]; then
    value=$(sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\(.*\)$/\1/p" Local.xcconfig | tail -1)
    value=$(printf '%s' "$value" | sed 's/[[:space:]]*$//')
  fi
  printf '%s' "$value"
}

TEAM=$(setting DEVELOPMENT_TEAM)
PREFIX=$(setting AI_USAGE_BUNDLE_PREFIX)
IDENTITY=$(setting SIGN_IDENTITY)
if [ -z "$TEAM" ]; then
  echo "Set DEVELOPMENT_TEAM (your Apple developer team ID) in macos/Local.xcconfig." >&2
  exit 1
fi
PREFIX=${PREFIX:-org.example}

cert_team() {  # cert_team SHA1 -> the team (OU) of that certificate in your keychains
  security find-certificate -a -Z -p | awk -v hash="$1" '
    /^SHA-1 hash:/ { keep = ($3 == hash) }
    keep && /BEGIN CERTIFICATE/ { printing = 1 }
    printing { print }
    /END CERTIFICATE/ { printing = 0 }' |
    openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU *= *\([A-Z0-9]*\).*/\1/p'
}

if [ -z "$IDENTITY" ]; then
  for hash in $(security find-identity -v -p codesigning | awk '/"Apple Development: / { print $2 }'); do
    if [ "$(cert_team "$hash")" = "$TEAM" ]; then IDENTITY=$hash; break; fi
  done
fi
if [ -z "$IDENTITY" ]; then
  echo "No Apple Development certificate for team $TEAM in your keychain. These can sign code:" >&2
  security find-identity -v -p codesigning >&2
  echo "Set SIGN_IDENTITY to one of them in macos/Local.xcconfig." >&2
  exit 1
fi

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
OUT=build.noindex
DISPLAY_NAME="AI Usage"
URL_SCHEME=aiusage
case "${1:-}" in
  --fresh-install)
    OUT="$OUT/FreshInstall"
    PREFIX="$PREFIX.freshinstall"
    DISPLAY_NAME="AI Usage Fresh Install"
    URL_SCHEME=aiusage-fresh-install
    ;;
  --setup-test)
    OUT="$OUT/SetupTest"
    PREFIX="$PREFIX.setuptest"
    DISPLAY_NAME="AI Usage Setup Test"
    URL_SCHEME=aiusage-setup-test
    ;;
  --claude-fresh-test)
    OUT="$OUT/ClaudeFreshTest"
    PREFIX="$PREFIX.claudefreshtest"
    DISPLAY_NAME="AI Usage Claude Fresh Test"
    URL_SCHEME=aiusage-claude-fresh-test
    ;;
  "") ;;
  *) echo "Usage: $0 [--fresh-install | --setup-test | --claude-fresh-test]" >&2; exit 1 ;;
esac
DERIVED="$OUT/DerivedData"
APP="$OUT/$DISPLAY_NAME.app"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

TEST_OPTIONS=()
case "${1:-}" in
  --setup-test|--claude-fresh-test)
    TEST_OPTIONS=("SWIFT_ACTIVE_COMPILATION_CONDITIONS=CLAUDE_QUOTA_TEST" "CURRENT_PROJECT_VERSION=13")
    CLAUDE_BIN=${CLAUDE_TEST_BINARY:-$(command -v claude || true)}
    [[ -n "$CLAUDE_BIN" && -x "$CLAUDE_BIN" ]] || { echo "Install Claude Code to build this private test." >&2; exit 1; }
    codesign --verify --strict -R '=anchor apple generic and identifier "com.anthropic.claude-code" and certificate leaf[subject.OU] = "Q6L2SF6YDW"' "$CLAUDE_BIN"
    ;;
esac
xcodegen generate --spec project.yml --quiet
xcodebuild -project AIUsage.xcodeproj -scheme AIUsage -configuration Release -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" DEVELOPMENT_TEAM="$TEAM" AI_USAGE_BUNDLE_PREFIX="$PREFIX" \
  AI_USAGE_DISPLAY_NAME="$DISPLAY_NAME" AI_USAGE_URL_SCHEME="$URL_SCHEME" \
  ARCHS=arm64 CODE_SIGNING_ALLOWED=NO ${TEST_OPTIONS[@]+"${TEST_OPTIONS[@]}"} build -quiet

# Keep one copy: LaunchServices and the widget gallery get confused by several.
BUILT="$DERIVED/Build/Products/Release/AI Usage.app"
rm -rf "$APP"
ditto "$BUILT" "$APP"
"$LSREGISTER" -u "$BUILT" 2>/dev/null || true
rm -rf "$BUILT"

if [[ -n "${CLAUDE_BIN:-}" && ${#TEST_OPTIONS[@]} -gt 0 ]]; then
  mkdir -p "$APP/Contents/Helpers"
  cp -L "$CLAUDE_BIN" "$APP/Contents/Helpers/claude"
  codesign --verify --strict "$APP/Contents/Helpers/claude"
fi

GROUP=$(/usr/libexec/PlistBuddy -c 'Print :AIUsageAppGroup' "$APP/Contents/Info.plist")
case "$GROUP" in
  "$TEAM".*) ;;
  *) echo "Unexpected App Group in the built Info.plist: $GROUP" >&2; exit 1 ;;
esac
sed "s/\$(AI_USAGE_APP_GROUP)/$GROUP/" Widget/AIUsageWidgets.entitlements > "$WORK/widgets.entitlements"
sed "s/\$(AI_USAGE_APP_GROUP)/$GROUP/" App/AIUsage.entitlements > "$WORK/app.entitlements"

# Inside out: the inherited-sandbox helper, widget, and containing app.
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" \
  --entitlements StoreTest/Helper/codex.entitlements "$APP/Contents/MacOS/codex-app-server"
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" \
  --entitlements "$WORK/widgets.entitlements" "$APP/Contents/PlugIns/AIUsageWidgets.appex"
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" \
  --entitlements "$WORK/app.entitlements" "$APP"
codesign --verify --deep --strict "$APP"

echo "Built and signed $PWD/$APP"
echo "App Group: $GROUP"
