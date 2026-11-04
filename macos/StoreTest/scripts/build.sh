#!/bin/bash
# Build the App Store test app unsigned, with OpenAI's Codex app-server inside, and put together a
# kit to copy to the Mac that signs and runs it (see ../README.md):
#
#   macos/StoreTest/scripts/build.sh     # -> macos/StoreTest/build.noindex/kit/
#
# Needs Xcode and XcodeGen. Reads AI_USAGE_BUNDLE_PREFIX from the environment or macos/Local.xcconfig.
# No signing identity is needed here: sign.sh in the kit signs both builds.
#
# The kit holds two builds of the same app: build 1, and build 2 with a higher build number, which
# the runner installs over build 1 the way an App Store update would replace it.
set -euo pipefail
cd "$(dirname "$0")/.."

# The Codex app-server release this test bundles, checked against its SHA-256 and OpenAI's signature.
CODEX_VERSION=0.166.0
CODEX_ASSET=codex-app-server-aarch64-apple-darwin.tar.gz
CODEX_SHA256=af848c48b91253faa5a693a71b30d963109efc2674b398aedd0ca29d13089ca4
CODEX_MEMBER=codex-app-server-aarch64-apple-darwin
CODEX_URL="https://github.com/openai/codex/releases/download/rust-v$CODEX_VERSION/$CODEX_ASSET"
OPENAI_TEAM=2DC432GLL2
HELPER_NAME=codex-app-server
# Codex's model list from the same tag: config.toml points model_catalog_json at it, so Codex never
# downloads one.
MODELS_URL="https://raw.githubusercontent.com/openai/codex/rust-v$CODEX_VERSION/codex-rs/models-manager/models.json"
MODELS_SHA256=1384625c0b6b3e67d3c60da29becea2b017f2c283fc1e2d05b8edafb4698eb10

setting() {  # setting NAME -> the environment's value, else ../Local.xcconfig's
  local value="${!1:-}"
  if [ -z "$value" ] && [ -f ../Local.xcconfig ]; then
    value=$(sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\(.*\)$/\1/p" ../Local.xcconfig | tail -1)
    value=$(printf '%s' "$value" | sed 's/[[:space:]]*$//')
  fi
  printf '%s' "$value"
}

PREFIX=$(setting AI_USAGE_BUNDLE_PREFIX)
PREFIX=${PREFIX:-org.example}
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
APP_NAME="AI Usage Store Test.app"
OUT=build.noindex
DERIVED="$OUT/DerivedData"
KIT="$OUT/kit"
STAGE="$OUT/stage"

# 1. Codex.
mkdir -p "$OUT/codex"
ARCHIVE="$OUT/codex/$CODEX_ASSET"
if ! printf '%s  %s\n' "$CODEX_SHA256" "$ARCHIVE" | shasum -a 256 -c - >/dev/null 2>&1; then
  curl -fL --retry 3 --proto '=https' -o "$ARCHIVE.part" "$CODEX_URL"
  mv "$ARCHIVE.part" "$ARCHIVE"
fi
printf '%s  %s\n' "$CODEX_SHA256" "$ARCHIVE" | shasum -a 256 -c -
rm -rf "$OUT/codex/x"
mkdir -p "$OUT/codex/x"
tar -xzf "$ARCHIVE" -C "$OUT/codex/x" "$CODEX_MEMBER"
CODEX="$OUT/codex/x/$CODEX_MEMBER"
codesign --verify --strict "$CODEX"
SIGNED_BY=$(codesign -dv "$CODEX" 2>&1 | sed -n 's/^TeamIdentifier=//p')
if [ "$SIGNED_BY" != "$OPENAI_TEAM" ]; then
  echo "$CODEX_MEMBER is signed by team '$SIGNED_BY', not OpenAI's $OPENAI_TEAM." >&2
  exit 1
fi
lipo -archs "$CODEX" | grep -qw arm64 || { echo "$CODEX_MEMBER isn't arm64." >&2; exit 1; }
MODELS="$OUT/codex/models.json"
if ! printf '%s  %s\n' "$MODELS_SHA256" "$MODELS" | shasum -a 256 -c - >/dev/null 2>&1; then
  curl -fL --retry 3 --proto '=https' -o "$MODELS.part" "$MODELS_URL"
  mv "$MODELS.part" "$MODELS"
fi
printf '%s  %s\n' "$MODELS_SHA256" "$MODELS" | shasum -a 256 -c -

# 2. The app and its widget, unsigned.
xcodegen generate --spec project.yml --quiet
xcodebuild -project AIUsageStoreTest.xcodeproj -scheme AIUsageStoreTest -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED" \
  AI_USAGE_BUNDLE_PREFIX="$PREFIX" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build -quiet

BUILT="$DERIVED/Build/Products/Release/$APP_NAME"
rm -rf "$STAGE" "$KIT"
mkdir -p "$STAGE/1" "$STAGE/2" "$KIT/entitlements"
ditto "$BUILT" "$STAGE/1/$APP_NAME"
# Keep one copy: LaunchServices and the widget gallery get confused by several.
"$LSREGISTER" -u "$BUILT" 2>/dev/null || true
rm -rf "$BUILT"

# 3. Codex goes next to the app's executable, the place for a helper tool in a sandboxed app.
ditto "$CODEX" "$STAGE/1/$APP_NAME/Contents/MacOS/$HELPER_NAME"
chmod 755 "$STAGE/1/$APP_NAME/Contents/MacOS/$HELPER_NAME"
mkdir -p "$STAGE/1/$APP_NAME/Contents/Resources"
cp "$MODELS" "$STAGE/1/$APP_NAME/Contents/Resources/codex-models.json"

# 4. Build 2: the same app with build number 2 (version 1.0.1), standing in for an update.
ditto "$STAGE/1/$APP_NAME" "$STAGE/2/$APP_NAME"
for plist in "$STAGE/2/$APP_NAME/Contents/Info.plist" \
             "$STAGE/2/$APP_NAME/Contents/PlugIns/StoreTestWidget.appex/Contents/Info.plist"; do
  /usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 2' -c 'Set :CFBundleShortVersionString 1.0.1' "$plist"
done

# 5. The kit: both builds zipped (so LaunchServices doesn't register them), the entitlements to sign
#    with, and the scripts.
ditto -c -k --keepParent "$STAGE/1/$APP_NAME" "$KIT/unsigned-1.zip"
ditto -c -k --keepParent "$STAGE/2/$APP_NAME" "$KIT/unsigned-2.zip"
rm -rf "$STAGE"
cp App/StoreTest.entitlements Widget/StoreTestWidget.entitlements Helper/codex.entitlements "$KIT/entitlements/"
cp scripts/sign.sh scripts/run.sh scripts/settings.js README.md "$KIT/"
chmod 755 "$KIT/sign.sh" "$KIT/run.sh"
printf 'codex %s (%s)\nmodels.json %s\nbundle %s.AIUsageStoreTest\n' "$CODEX_VERSION" "$CODEX_SHA256" "$MODELS_SHA256" "$PREFIX" \
  > "$KIT/BUILD-INFO.txt"
echo "Kit ready: $PWD/$KIT"
ls -la "$KIT"
