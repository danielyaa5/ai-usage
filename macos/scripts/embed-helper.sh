#!/bin/bash
# Build-time only; the installed app never downloads code or invokes a system CLI.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cache="$root/build.noindex/vendor"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir -p "$cache"
asset=codex-app-server-aarch64-apple-darwin
tag=rust-v0.166.0
obtain() {
  local name=$1 sha=$2 url=$3
  if ! (cd "$cache" && printf '%s  %s\n' "$sha" "$name" | shasum -a 256 -c --status) 2>/dev/null; then
    curl --fail --location --retry 2 --proto '=https' "$url" -o "$stage/$name"
    (cd "$stage" && printf '%s  %s\n' "$sha" "$name" | shasum -a 256 -c --status)
    mv "$stage/$name" "$cache/$name"
  fi
}
obtain "$asset.tar.gz" af848c48b91253faa5a693a71b30d963109efc2674b398aedd0ca29d13089ca4 \
  "https://github.com/openai/codex/releases/download/$tag/$asset.tar.gz"
obtain models.json 1384625c0b6b3e67d3c60da29becea2b017f2c283fc1e2d05b8edafb4698eb10 \
  "https://raw.githubusercontent.com/openai/codex/$tag/codex-rs/models-manager/models.json"
tar -xOzf "$cache/$asset.tar.gz" "$asset" > "$stage/codex-app-server"
chmod 755 "$stage/codex-app-server"
codesign --verify --strict "$stage/codex-app-server"
signer=$(codesign -dv "$stage/codex-app-server" 2>&1)
grep -qx 'TeamIdentifier=2DC432GLL2' <<< "$signer" || { echo "Unexpected Codex signing team." >&2; exit 1; }
if [[ "${CODE_SIGNING_ALLOWED:-NO}" == YES && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp=none --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
    --entitlements "$root/StoreTest/Helper/codex.entitlements" "$stage/codex-app-server"
fi
bin="$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH"
resources="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
mkdir -p "$bin" "$resources"
ditto "$stage/codex-app-server" "$bin/codex-app-server"
cp "$cache/models.json" "$resources/codex-models.json"
