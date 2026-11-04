#!/bin/bash
# Runs the AI Usage store test on this Mac (see README.md). In a kit folder made by build.sh (it
# runs sign.sh first when the builds aren't signed yet):
#
#   ./run.sh [DASHBOARD_URL]
#
# DASHBOARD_URL is an AI Usage dashboard on another Mac on your network, such as
# http://my-mac.local:8796/api/widget, for the local network checks. It can also come from a
# local.env file next to this script (LAN_URL=...).
#
# It installs build 1 in /Applications and opens it for the interactive checks, then checks the
# Claude Code status line snippet with you (it switches your status line for a minute, if you agree,
# and puts it back), relaunches the app, installs build 2 over it the way an update would, and
# collects everything in results/<time>/ next to this script.
set -uo pipefail

# It asks you questions, so it needs a terminal: without one, every answer would be a guess.
if ! { : </dev/tty; } 2>/dev/null; then
  echo "Run this in Terminal: it asks you questions as it goes." >&2
  exit 1
fi

KIT=$(cd "$(dirname "$0")" && pwd)
APP_NAME="AI Usage Store Test"
APP="/Applications/$APP_NAME.app"
HELPER="$APP/Contents/MacOS/codex-app-server"
# macOS keeps only the first 16 characters of a process name, so the app is found by its executable's
# path: pgrep -x "AI Usage Store Test" would never match.
APP_PATTERN="^$APP/Contents/MacOS/$APP_NAME( |\$)"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
CLAUDE_DIR=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
SETTINGS="$CLAUDE_DIR/settings.json"

[ -f "$KIT/local.env" ] && . "$KIT/local.env"
LAN_URL=${1:-${LAN_URL:-}}

STAMP=$(date -u +%Y%m%d-%H%M%SZ)
OUT="$KIT/results/$STAMP"
mkdir -p "$OUT"
ln -sfn "$STAMP" "$KIT/results/latest"
# tee ignores Ctrl-C, so the cleanup after one can still tell you whether your settings are back.
exec > >(trap '' INT TERM HUP; exec tee -a "$OUT/runner.log") 2>&1
LOG_START=$(date '+%Y-%m-%d %H:%M:%S')

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

ask() {  # ask QUESTION y|n -> status 0 for yes
  local reply hint="[y/N]"
  [ "$2" = y ] && hint="[Y/n]"
  while true; do
    printf '%s %s ' "$1" "$hint"
    if ! IFS= read -r reply </dev/tty; then
      echo "Couldn't read an answer, so the test stopped."
      exit 1
    fi
    reply=$(printf '%s' "$reply" | tr '[:upper:]' '[:lower:]')
    [ -z "$reply" ] && reply=$2
    case "$reply" in
      y|yes) echo "  -> yes" >> "$OUT/answers.txt"; return 0 ;;
      n|no) echo "  -> no" >> "$OUT/answers.txt"; return 1 ;;
    esac
  done
}

api() {  # api METHOD PATH [curl options...]
  local method=$1 path=$2
  shift 2
  curl -q -sS -m 15 --noproxy '*' -X "$method" -H "X-AI-Usage-Token: $TOKEN" "$@" "http://127.0.0.1:$PORT$path"
}

state() { api GET /state 2>/dev/null; }
state_value() { state | tr ' ' '\n' | sed -n "s/^$1=//p"; }

json_string() {  # json_string TEXT -> a JSON string literal
  printf '%s' "$1" | osascript -l JavaScript -e 'function run() { return JSON.stringify(ObjC.unwrap($.NSString.alloc.initWithDataEncoding($.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile, $.NSUTF8StringEncoding))) }'
}

note() {  # note ID TEST TITLE STATUS DETAIL: record something the runner saw with the app's results
  local body
  body="{\"id\":$(json_string "$1"),\"test\":$2,\"title\":$(json_string "$3"),\"status\":$(json_string "$4"),\"detail\":$(json_string "$5")}"
  printf '%s' "$body" | api POST /note -H 'Content-Type: application/json' --data-binary @- >/dev/null 2>&1 || true
  printf '%s\t%s\t%s\n' "$1" "$4" "$5" >> "$OUT/runner-notes.txt"
}

app_pids() { pgrep -f "$APP_PATTERN"; }
app_running() { app_pids >/dev/null 2>&1; }

quit_app() {
  if app_running; then
    api POST /quit >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
      app_running || break
      sleep 0.5
    done
    pkill -f "$APP_PATTERN" 2>/dev/null || true
    sleep 1
  fi
  pkill -f "$HELPER" 2>/dev/null || true
}

install_build() {  # install_build 1|2
  local zip="$KIT/signed-$1.zip" existing
  [ -f "$zip" ] || { echo "Missing $zip: run sign.sh first."; exit 1; }
  quit_app
  if [ -d "$APP" ]; then
    existing=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)
    case "$existing" in
      *.AIUsageStoreTest) ;;
      *) echo "$APP belongs to another app ($existing); not replacing it."; exit 1 ;;
    esac
    rm -rf "$APP"
  fi
  ditto --noqtn -x -k "$zip" /Applications || { echo "Couldn't install into /Applications."; exit 1; }
  xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
  touch "$APP"
  "$LSREGISTER" -f "$APP"
  pluginkit -a "$APP/Contents/PlugIns/StoreTestWidget.appex" 2>/dev/null || true
  if codesign --verify --deep --strict "$APP" 2>>"$OUT/runner-errors.txt"; then
    echo "Installed build $1 in /Applications."
  else
    echo "Build $1's signature doesn't verify; see runner-errors.txt."
  fi
  {
    echo "== build $1"
    for code in "$APP" "$APP/Contents/PlugIns/StoreTestWidget.appex" "$HELPER"; do
      codesign -dv --verbose=2 "$code" 2>&1 | grep -E '^(Identifier=|Format=|CodeDirectory |TeamIdentifier=|Runtime Version=)'
      codesign -d --entitlements - --xml "$code" 2>/dev/null | tr -d '\n\t'
      echo
    done
  } >> "$OUT/signatures.txt"
  # macOS takes in a new build for a few seconds; a widget extension from the old one keeps running.
  sleep 5
  pkill -x StoreTestWidget 2>/dev/null || true
}

launch() {  # launch PHASE
  local phase=$1
  : > "$OUT/app-$phase.out"
  : > "$OUT/app-$phase.err"
  if ! open --stdout "$OUT/app-$phase.out" --stderr "$OUT/app-$phase.err" "$APP" --args \
      --phase "$phase" --port "$PORT" --token "$TOKEN" ${LAN_URL:+--lan-url "$LAN_URL"}; then
    open "$APP" --args --phase "$phase" --port "$PORT" --token "$TOKEN" ${LAN_URL:+--lan-url "$LAN_URL"}
  fi
  local reply
  for _ in $(seq 1 60); do
    # Only the instance started for this phase counts, not one left running from before.
    reply=$(curl -q -s -m 1 --noproxy '*' "http://127.0.0.1:$PORT/ping" 2>/dev/null)
    case "$reply" in *"\"phase\":\"$phase\""*) return 0 ;; esac
    sleep 0.5
  done
  echo "The app didn't answer for the $phase phase on 127.0.0.1:$PORT within 30 seconds."
  return 1
}

save() {  # save PHASE: the app's full results and summary
  local phase=$1
  if api GET /results > "$OUT/$phase.json.part" 2>/dev/null && [ -s "$OUT/$phase.json.part" ]; then
    mv "$OUT/$phase.json.part" "$OUT/$phase.json"
  else
    rm -f "$OUT/$phase.json.part"
  fi
  if api GET /summary > "$OUT/$phase-summary.txt.part" 2>/dev/null && [ -s "$OUT/$phase-summary.txt.part" ]; then
    mv "$OUT/$phase-summary.txt.part" "$OUT/$phase-summary.txt"
  else
    rm -f "$OUT/$phase-summary.txt.part"
  fi
}

# Every 2 seconds: the app's process tree and the Codex helper's network connections, when they change.
sampler() {
  local last_tree="" last_net="" tree net pid
  while true; do
    pid=$(app_pids | head -1)
    if [ -n "$pid" ]; then
      tree=$(ps -axo pid=,ppid=,command= | awk -v root="$pid" '
        { parent[$1] = $2; line[$1] = $0 }
        END { for (p in line) { q = p; for (i = 0; i < 50 && q != "" && q > 1; i++) { if (q == root) { print line[p]; break } q = parent[q] } } }' |
        sort -n | sed -e "s/$TOKEN/TOKEN/g" -e 's/--lan-url [^ ]*/--lan-url LAN_URL/')
      if [ "$tree" != "$last_tree" ]; then
        printf '%s\n%s\n\n' "$(date -u +%H:%M:%S)" "$tree" >> "$OUT/processes.txt"
        last_tree=$tree
      fi
      net=""
      for helper in $(pgrep -f "$HELPER"); do
        net="$net$(lsof -nP -a -p "$helper" -i 2>/dev/null | awk 'NR > 1 { print $8, $9, $10 }')
"
      done
      if [ "$net" != "$last_net" ]; then
        printf '%s\n%s\n' "$(date -u +%H:%M:%S)" "$net" >> "$OUT/connections.txt"
        last_net=$net
      fi
    fi
    sleep 2
  done
}

# Step 4 switches statusLine in your Claude Code settings for a minute. The backup goes in a private
# folder next to this script, not in results/, and is deleted once your settings are checked back.
SWITCHED=0          # 1 from just before the switch until the settings are checked back
SETTINGS_FILE=""    # settings.json with a symlink resolved, so the link itself is kept
SETTINGS_EXISTED=0
SETTINGS_MODE=""
BACKUP_DIR=""
SKIP_REASON=""

back_up_settings() {  # back_up_settings SNIPPET -> status 0 when the backup is safe and the switch can go ahead
  SETTINGS_FILE=$SETTINGS
  if [ ! -d "$CLAUDE_DIR" ]; then
    SKIP_REASON="Claude Code's settings folder $CLAUDE_DIR isn't there."
    return 1
  fi
  if [ -L "$SETTINGS" ]; then
    SETTINGS_FILE=$(/bin/realpath "$SETTINGS" 2>/dev/null) || SETTINGS_FILE=""
    if [ -z "$SETTINGS_FILE" ] || [ ! -f "$SETTINGS_FILE" ]; then
      SKIP_REASON="$SETTINGS is a symlink to a file that isn't there."
      return 1
    fi
  fi
  if [ -e "$SETTINGS_FILE" ] && [ ! -f "$SETTINGS_FILE" ]; then
    SKIP_REASON="$SETTINGS isn't a regular file."
    return 1
  fi
  if [ -f "$SETTINGS_FILE" ] && [ "$(stat -f %l "$SETTINGS_FILE")" -gt 1 ]; then
    SKIP_REASON="$SETTINGS has other hard links, which rewriting it would break."
    return 1
  fi
  BACKUP_DIR="$KIT/settings-backup/$STAMP"
  if ! (umask 077 && mkdir -p "$BACKUP_DIR"); then
    SKIP_REASON="Couldn't make the backup folder $BACKUP_DIR."
    return 1
  fi
  SETTINGS_EXISTED=0
  SETTINGS_MODE=""
  if [ -f "$SETTINGS_FILE" ]; then
    SETTINGS_EXISTED=1
    SETTINGS_MODE=$(stat -f %Lp "$SETTINGS_FILE")
    if ! cp -p "$SETTINGS_FILE" "$BACKUP_DIR/settings.json" || ! cmp -s "$SETTINGS_FILE" "$BACKUP_DIR/settings.json"; then
      SKIP_REASON="Couldn't back up $SETTINGS."
      rm -rf "$BACKUP_DIR"
      return 1
    fi
  fi
  if ! osascript -l JavaScript "$KIT/settings.js" get "$SETTINGS_FILE" > "$BACKUP_DIR/statusline-before.json" 2>>"$OUT/runner-errors.txt"; then
    SKIP_REASON="Couldn't read the statusLine setting in $SETTINGS."
    rm -rf "$BACKUP_DIR"
    return 1
  fi
  printf '%s' "$1" > "$BACKUP_DIR/snippet.txt"
}

restore_status_line() {
  [ "$SWITCHED" = 1 ] || return 0
  local before="$BACKUP_DIR/statusline-before.json" original="$BACKUP_DIR/settings.json"
  local written="$BACKUP_DIR/settings.json.written" partial="$SETTINGS_FILE.ai-usage-restore"
  rm -f "$partial"
  if [ "$SETTINGS_EXISTED" = 1 ]; then
    if cmp -s "$original" "$SETTINGS_FILE"; then
      :   # never changed
    elif [ -f "$written" ] && cmp -s "$written" "$SETTINGS_FILE"; then
      # Nothing else changed it: put the original file back exactly, through a copy renamed into
      # place, so an interruption can't leave half a file.
      cp -p "$original" "$partial" && mv -f "$partial" "$SETTINGS_FILE"
    else
      # Claude Code changed something meanwhile: keep that, and put back only statusLine.
      osascript -l JavaScript "$KIT/settings.js" restore "$SETTINGS_FILE" "$before" >/dev/null 2>>"$OUT/runner-errors.txt"
      [ -n "$SETTINGS_MODE" ] && chmod "$SETTINGS_MODE" "$SETTINGS_FILE"
    fi
  elif [ -f "$SETTINGS_FILE" ]; then
    if [ -f "$written" ] && cmp -s "$written" "$SETTINGS_FILE"; then
      rm -f "$SETTINGS_FILE"   # the test made this file, and nothing else changed it
    else
      osascript -l JavaScript "$KIT/settings.js" restore "$SETTINGS_FILE" "$before" >/dev/null 2>>"$OUT/runner-errors.txt"
    fi
  fi
  if [ "$(osascript -l JavaScript "$KIT/settings.js" get "$SETTINGS_FILE" 2>/dev/null)" = "$(cat "$before")" ]; then
    if [ "$SETTINGS_EXISTED" = 0 ] || cmp -s "$original" "$SETTINGS_FILE"; then
      echo "Your Claude Code settings are back exactly as they were."
    else
      echo "Your status line setting is back as it was. Claude Code changed other settings meanwhile; those are kept."
    fi
    rm -rf "$BACKUP_DIR"
    rmdir "$KIT/settings-backup" 2>/dev/null || true
  else
    echo "WARNING: couldn't put your status line back in $SETTINGS."
    if [ "$SETTINGS_EXISTED" = 1 ]; then
      echo "Your original settings file is at $original"
    else
      echo "You had no settings file there before the test, so you can delete it."
    fi
  fi
  SWITCHED=0
}

is_snippet() { case "$1" in ': ai-usage-v1;'*) return 0 ;; *) return 1 ;; esac; }

INSTALLED=0    # set once build 1 is installed
SIGNED_OUT=0   # set once the update phase, which signs the test out of ChatGPT, has finished

# A port and token for the app's test listener, kept between runs so a pasted snippet stays valid.
# They're loaded before the cleanup is set up, so it can quit an app left over from an earlier run.
STATE="$KIT/state.env"
PORT=""
TOKEN=""
[ -f "$STATE" ] && . "$STATE"

cleanup() {
  trap '' INT TERM HUP PIPE   # a second Ctrl-C can't cut the cleanup short
  [ -n "${SAMPLER:-}" ] && kill "$SAMPLER" 2>/dev/null
  restore_status_line
  quit_app
  if [ "$INSTALLED" = 1 ] && [ "$SIGNED_OUT" = 0 ]; then
    echo "The test stopped before its last step, where it signs out of ChatGPT, so its own sign-in may"
    echo "still be in the app's container. Deleting the app's containers (see README.md) removes it."
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM
trap 'exit 129' HUP

# A made-up status line input in Claude Code's shape. Its limits reset in 2100, which tells the app
# it's this self-test, not Claude Code.
SAMPLE='{"session_id":"00000000-0000-4000-8000-000000000000","transcript_path":"/tmp/example.jsonl","cwd":"/tmp/example {braces} \"quoted\"","session_name":"a \"rate_limits\":{\"five_hour\":{}} lookalike","model":{"id":"claude-example","display_name":"Example"},"workspace":{"current_dir":"/tmp","project_dir":"/tmp","added_dirs":[]},"version":"2.1.318","output_style":{"name":"default"},"cost":{"total_cost_usd":0.01,"total_duration_ms":1000,"total_api_duration_ms":500,"total_lines_added":1,"total_lines_removed":0},"context_window":{"total_input_tokens":0,"total_output_tokens":0,"context_window_size":200000,"current_usage":null,"used_percentage":null,"remaining_percentage":null},"exceeds_200k_tokens":false,"rate_limits":{"five_hour":{"used_percentage":11.5,"resets_at":4102444800},"seven_day":{"used_percentage":22.5,"resets_at":4102444800}},"vim":{"mode":"INSERT"}}'

selftest() {  # selftest SNIPPET SHELL LABEL
  local snippet=$1 shell=$2 label=$3 before after bad_before bad_after seconds output expected why=""
  before=$(state_value sample)
  bad_before=$(state_value samplebad)
  printf '%s\n' "$SAMPLE" > "$OUT/sample-input.json"
  # The self-test's status line command prints a checksum of its input, so this shows it got all of it.
  expected="STATUS-OK $(cksum < "$OUT/sample-input.json")"
  /usr/bin/time -p "$shell" -c "$snippet" < "$OUT/sample-input.json" > "$OUT/selftest-$label.out" 2> "$OUT/selftest-$label.time"
  seconds=$(awk '/^real/ { print $2 }' "$OUT/selftest-$label.time")
  output=$(cat "$OUT/selftest-$label.out")
  sleep 2
  after=$(state_value sample)
  bad_after=$(state_value samplebad)
  [ "$output" = "$expected" ] || why="the command's output was '$output', not '$expected'; "
  [ "${after:-0}" -gt "${before:-0}" ] || why="${why}no reading reached the app; "
  [ "${bad_after:-0}" -le "${bad_before:-0}" ] || why="${why}the app got more than the sample's limits; "
  if [ -z "$why" ]; then
    note "statusline.selftest-$label" 4 "Snippet self-test ($label)" passed "Sent only the sample's limits to the app and passed the whole input on, in $seconds s."
    echo "  ✓ $label: passed the whole input on and sent only the limits ($seconds s)"
  else
    why=${why%; }
    note "statusline.selftest-$label" 4 "Snippet self-test ($label)" failed "$why ($seconds s)."
    echo "  ✗ $label: $why"
  fi
}

# ---------------------------------------------------------------------------------------------------

say "AI Usage store test"
cat <<EOF
This installs a test app, "$APP_NAME", in /Applications and walks you through four checks:
your local network and a test widget, picking your .claude and .codex folders, signing in
to ChatGPT through the bundled Codex, and your Claude Code status line. About ten minutes.
Results go to $OUT
EOF
if [ -n "$LAN_URL" ]; then
  printf 'Dashboard on your network: %s\n' "$LAN_URL" >/dev/tty
  echo "A dashboard address on your network was given."
else
  echo "No dashboard address given, so the network check is skipped."
fi
ask "Start?" y || exit 0

quit_app
if [ -z "$PORT" ] || lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    PORT=$((49200 + RANDOM % 15000))
    lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 || break
  done
fi
[ -n "$TOKEN" ] || TOKEN=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 32)
umask 077
printf 'PORT=%s\nTOKEN=%s\n' "$PORT" "$TOKEN" > "$STATE"
umask 022
{ sw_vers; uname -m; echo "port $PORT"; cat "$KIT/BUILD-INFO.txt" 2>/dev/null; } > "$OUT/system.txt"

if [ ! -f "$KIT/signed-1.zip" ] || [ ! -f "$KIT/signed-2.zip" ] ||
   [ "$KIT/unsigned-1.zip" -nt "$KIT/signed-1.zip" ] || [ "$KIT/unsigned-2.zip" -nt "$KIT/signed-2.zip" ]; then
  say "Signing the two builds"
  echo "With your Apple Development certificate. If macOS asks to let codesign use a key in your"
  echo "keychain, enter your password and click Always Allow (or Allow, once for each build)."
  if ! "$KIT/sign.sh"; then
    echo "Signing failed (see above), so the test stopped."
    exit 1
  fi
fi

say "Installing build 1"
install_build 1
INSTALLED=1
sampler &
SAMPLER=$!

say "Steps 1 to 3 are in the app window"
launch first || exit 1
echo "Work through steps 1 to 3 in the app window, then click Continue in Terminal there."
echo "(Or press Enter here to move on.)"
while app_running; do
  [ "$(state_value handoff)" = 1 ] && break
  if IFS= read -r -t 5 _ </dev/tty; then break; fi
  save first
done
save first

say "Step 4: your Claude Code status line"
if ! app_running; then
  echo "The app isn't running any more; skipping the status line check."
else
  CURRENT=$(osascript -l JavaScript "$KIT/settings.js" command "$SETTINGS" 2>>"$OUT/runner-errors.txt")
  READ_STATUS=$?
  if [ "$READ_STATUS" -ne 0 ]; then
    echo "Couldn't read $SETTINGS as JSON, so the status line part is skipped."
    note statusline.settings 4 "Your Claude Code settings" skipped "settings.json couldn't be read as JSON."
  else
    if [ -n "$CURRENT" ]; then
      # Shown on screen only, so your command stays out of the results.
      printf 'Your status line command now: %s\n' "$CURRENT" >/dev/tty
      echo "You have a status line command (${#CURRENT} characters)."
    else
      echo "You have no status line command now."
    fi
    echo "First, a self-test with made-up numbers (your settings aren't touched):"
    TEST_SNIPPET=$(printf '%s' 'printf "STATUS-OK "; cksum' | api POST /snippet -H 'X-Snippet-Purpose: test' --data-binary @-)
    if ! is_snippet "$TEST_SNIPPET"; then
      echo "The app didn't build a snippet."
      note statusline.selftest 4 "Snippet self-test" failed "The app didn't build a snippet."
    else
      printf '%s\n' "$TEST_SNIPPET" | sed "s/$TOKEN/TOKEN/g" > "$OUT/snippet-selftest.txt"
      # Every reading in this time is the self-test's, even one the snippet got wrong.
      api POST /selftest --data-binary start >/dev/null 2>&1 || true
      selftest "$TEST_SNIPPET" /bin/sh "sh"
      selftest "$TEST_SNIPPET" /bin/zsh "zsh"
      selftest "$(printf '%s' "$TEST_SNIPPET" | sed 's#/usr/bin/jq#/nonexistent/jq#g')" /bin/sh "sed-fallback"
      api POST /selftest --data-binary stop >/dev/null 2>&1 || true
      [ -x /usr/bin/jq ] && note statusline.jq 4 "/usr/bin/jq on this Mac" info "$(/usr/bin/jq --version 2>&1)" \
        || note statusline.jq 4 "/usr/bin/jq on this Mac" info "not installed (the snippet uses sed)"
    fi
    SNIPPET=$(printf '%s' "$CURRENT" | api POST /snippet --data-binary @-)
    if ! is_snippet "$SNIPPET"; then
      echo "The app didn't build the snippet; skipping."
      note statusline.switch 4 "Status line switched for the test" failed "The app didn't build the snippet."
    elif ask "Switch your Claude Code status line to the test snippet now? Your settings are backed up first and put back right after." y; then
      if ! back_up_settings "$SNIPPET"; then
        echo "$SKIP_REASON So the switch is skipped, and your settings weren't touched."
        note statusline.switch 4 "Status line switched for the test" skipped "$SKIP_REASON"
      else
        SWITCHED=1
        if osascript -l JavaScript "$KIT/settings.js" set "$SETTINGS_FILE" "$BACKUP_DIR/snippet.txt" >/dev/null 2>>"$OUT/runner-errors.txt"; then
          [ -n "$SETTINGS_MODE" ] && chmod "$SETTINGS_MODE" "$SETTINGS_FILE"
          cp -p "$SETTINGS_FILE" "$BACKUP_DIR/settings.json.written"
          echo
          echo "Done. Now start a new Claude Code session in another Terminal tab (cd ~ && claude, and say"
          echo "yes if it asks whether you trust the folder), send a short message such as \"hi\" and wait for"
          echo "the reply. Check that your status line looks as it did."
          echo "Waiting for a reading from Claude Code (press Enter to stop waiting)..."
          BEFORE=$(state_value claude)
          NOW=$BEFORE
          WAITED=0
          while [ "$WAITED" -lt 600 ]; do
            NOW=$(state_value claude)
            if [ "${NOW:-0}" -gt "${BEFORE:-0}" ]; then
              echo "Got a reading from Claude Code."
              sleep 3
              break
            fi
            if IFS= read -r -t 5 _ </dev/tty; then break; fi
            WAITED=$((WAITED + 5))
          done
          if [ "${NOW:-0}" -le "${BEFORE:-0}" ]; then
            note statusline.claude 4 "Readings from Claude Code's status line" failed "No reading arrived (waited $WAITED s)."
          fi
          save first
          if ask "Did your status line look the same as before?" y; then
            note statusline.looks-same 4 "Your status line looked the same" passed "You said yes."
          else
            note statusline.looks-same 4 "Your status line looked the same" failed "You said no."
          fi
          if ask "Did anything ask you for permission (macOS or Claude Code)?" n; then
            note statusline.prompts 4 "No prompts during the hand-off" failed "You saw a prompt."
          else
            note statusline.prompts 4 "No prompts during the hand-off" passed "You saw none."
          fi
        else
          echo "Couldn't write $SETTINGS; skipping."
          note statusline.switch 4 "Status line switched for the test" failed "settings.json couldn't be written."
        fi
        restore_status_line
      fi
    else
      note statusline.switch 4 "Status line switched for the test" skipped "You chose not to."
    fi
  fi
fi
if app_running && [ "$(state_value codex)" = busy ]; then
  echo "Waiting for the ChatGPT check in the app to finish..."
  for _ in $(seq 1 100); do
    [ "$(state_value codex)" = busy ] || break
    sleep 3
  done
fi
save first
quit_app

say "Relaunching the app (it checks by itself)"
if launch relaunch; then
  for _ in $(seq 1 60); do
    [ "$(state_value done)" = 1 ] && break
    sleep 3
  done
  save relaunch
fi
quit_app

say "Installing build 2 over it, as an update would, and checking again"
install_build 2
if launch update; then
  for _ in $(seq 1 60); do
    [ "$(state_value done)" = 1 ] && break
    sleep 3
  done
  [ "$(state_value done)" = 1 ] && SIGNED_OUT=1
  save update
fi
quit_app
kill "$SAMPLER" 2>/dev/null
SAMPLER=""

say "Collecting logs"
/usr/bin/log show --style ndjson --start "$LOG_START" --predicate 'subsystem == "AIUsageStoreTest"' > "$OUT/unified-log.ndjson" 2>/dev/null
/usr/bin/log show --style compact --start "$LOG_START" \
  --predicate 'eventMessage CONTAINS[c] "deny" AND (eventMessage CONTAINS "codex-app-server" OR eventMessage CONTAINS "AI Usage Store T" OR eventMessage CONTAINS "StoreTestWidget")' \
  > "$OUT/sandbox-denials.txt" 2>/dev/null
/usr/bin/log show --style compact --start "$LOG_START" --predicate 'process == "nehelper"' 2>/dev/null |
  grep -i 'AIUsageStoreTest\|Store Test\|StoreTestWidget' > "$OUT/local-network.txt"
mkdir -p "$OUT/crashes"
find "$HOME/Library/Logs/DiagnosticReports" -maxdepth 1 -newer "$OUT/system.txt" \
  \( -name 'codex-app-server*' -o -name 'AI Usage Store Test*' -o -name 'StoreTestWidget*' \) \
  -exec cp {} "$OUT/crashes/" \; 2>/dev/null
pluginkit -m -v -i "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist").Widget" > "$OUT/pluginkit.txt" 2>&1

for phase in first relaunch update; do
  [ -f "$OUT/$phase-summary.txt" ] && { cat "$OUT/$phase-summary.txt"; echo; }
done > "$OUT/summary.txt"
say "Summary"
cat "$OUT/summary.txt"
echo
echo "All done. The results are in $OUT"
echo "You can remove the Store Test widget now. Reply \"done\" in the thread."
