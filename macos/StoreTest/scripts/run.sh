#!/bin/bash
# Runs the AI Usage store test on this Mac (see README.md). In a kit folder made by build.sh and
# signed by sign.sh:
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

KIT=$(cd "$(dirname "$0")" && pwd)
APP_NAME="AI Usage Store Test"
APP="/Applications/$APP_NAME.app"
HELPER="$APP/Contents/MacOS/codex-app-server"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
SETTINGS="$HOME/.claude/settings.json"

[ -f "$KIT/local.env" ] && . "$KIT/local.env"
LAN_URL=${1:-${LAN_URL:-}}

STAMP=$(date -u +%Y%m%d-%H%M%SZ)
OUT="$KIT/results/$STAMP"
mkdir -p "$OUT"
ln -sfn "$STAMP" "$KIT/results/latest"
exec > >(tee -a "$OUT/runner.log") 2>&1
LOG_START=$(date '+%Y-%m-%d %H:%M:%S')

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

ask() {  # ask QUESTION y|n -> status 0 for yes
  local reply hint="[y/N]"
  [ "$2" = y ] && hint="[Y/n]"
  while true; do
    printf '%s %s ' "$1" "$hint"
    IFS= read -r reply </dev/tty || reply=""
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

app_running() { pgrep -x "$APP_NAME" >/dev/null 2>&1; }

quit_app() {
  if app_running; then
    api POST /quit >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
      app_running || break
      sleep 0.5
    done
    pkill -x "$APP_NAME" 2>/dev/null || true
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
  ditto -x -k "$zip" /Applications || { echo "Couldn't install into /Applications."; exit 1; }
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
      codesign -dv --verbose=2 "$code" 2>&1 | grep -E '^(Identifier|Format|CodeDirectory|TeamIdentifier|Runtime Version)='
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
  for _ in $(seq 1 60); do
    curl -q -s -m 1 --noproxy '*' "http://127.0.0.1:$PORT/ping" >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  echo "The app didn't answer on 127.0.0.1:$PORT within 30 seconds."
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
    pid=$(pgrep -x "$APP_NAME" | head -1)
    if [ -n "$pid" ]; then
      tree=$(ps -axo pid=,ppid=,command= | awk -v root="$pid" '
        { parent[$1] = $2; line[$1] = $0 }
        END { for (p in line) { q = p; for (i = 0; i < 50 && q != "" && q > 1; i++) { if (q == root) { print line[p]; break } q = parent[q] } } }' | sort -n)
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

STATUS_BACKUP=""
STATUS_OLD=""
STATUS_WRITTEN=""
SETTINGS_EXISTED=0
SETTINGS_MODE=""

restore_status_line() {
  [ -n "$STATUS_BACKUP" ] || return 0
  if [ "$SETTINGS_EXISTED" = 0 ]; then
    if [ -n "$STATUS_WRITTEN" ] && cmp -s "$STATUS_WRITTEN" "$SETTINGS"; then
      rm -f "$SETTINGS"
    else
      osascript -l JavaScript "$KIT/settings.js" restore "$SETTINGS" "$STATUS_OLD" >/dev/null
    fi
  elif [ -n "$STATUS_WRITTEN" ] && cmp -s "$STATUS_WRITTEN" "$SETTINGS"; then
    cp -p "$STATUS_BACKUP" "$SETTINGS"   # nothing else changed it: put the original file back exactly
  else
    osascript -l JavaScript "$KIT/settings.js" restore "$SETTINGS" "$STATUS_OLD" >/dev/null
    [ -n "$SETTINGS_MODE" ] && chmod "$SETTINGS_MODE" "$SETTINGS"
  fi
  if [ "$(osascript -l JavaScript "$KIT/settings.js" get "$SETTINGS" 2>/dev/null)" = "$(cat "$STATUS_OLD")" ]; then
    echo "Your status line setting is back as it was."
  else
    echo "WARNING: couldn't put your status line back. Your original settings file is at $STATUS_BACKUP"
  fi
  STATUS_BACKUP=""
}

cleanup() {
  restore_status_line
  [ -n "${SAMPLER:-}" ] && kill "$SAMPLER" 2>/dev/null
  quit_app
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# A made-up status line input in Claude Code's shape. Its limits reset in 2100, which tells the app
# it's this self-test, not Claude Code.
SAMPLE='{"session_id":"00000000-0000-4000-8000-000000000000","transcript_path":"/tmp/example.jsonl","cwd":"/tmp/example {braces} \"quoted\"","session_name":"a \"rate_limits\":{\"five_hour\":{}} lookalike","model":{"id":"claude-example","display_name":"Example"},"workspace":{"current_dir":"/tmp","project_dir":"/tmp","added_dirs":[]},"version":"2.1.318","output_style":{"name":"default"},"cost":{"total_cost_usd":0.01,"total_duration_ms":1000,"total_api_duration_ms":500,"total_lines_added":1,"total_lines_removed":0},"context_window":{"total_input_tokens":0,"total_output_tokens":0,"context_window_size":200000,"current_usage":null,"used_percentage":null,"remaining_percentage":null},"exceeds_200k_tokens":false,"rate_limits":{"five_hour":{"used_percentage":11.5,"resets_at":4102444800},"seven_day":{"used_percentage":22.5,"resets_at":4102444800}},"vim":{"mode":"INSERT"}}'

selftest() {  # selftest SNIPPET SHELL LABEL
  local snippet=$1 shell=$2 label=$3 before after seconds output
  before=$(state_value sample)
  printf '%s\n' "$SAMPLE" > "$OUT/sample-input.json"
  /usr/bin/time -p "$shell" -c "$snippet" < "$OUT/sample-input.json" > "$OUT/selftest-$label.out" 2> "$OUT/selftest-$label.time"
  seconds=$(awk '/^real/ { print $2 }' "$OUT/selftest-$label.time")
  output=$(cat "$OUT/selftest-$label.out")
  sleep 2
  after=$(state_value sample)
  if [ "$output" = "STATUS-OK" ] && [ "${after:-0}" -gt "${before:-0}" ]; then
    note "statusline.selftest-$label" 4 "Snippet self-test ($label)" passed "Sent the sample's limits to the app and passed the input on, in $seconds s."
    echo "  ✓ $label: passed the input on and sent the limits ($seconds s)"
  else
    note "statusline.selftest-$label" 4 "Snippet self-test ($label)" failed "Output '$output', app readings $before -> $after, $seconds s."
    echo "  ✗ $label: output '$output', app readings ${before:-?} -> ${after:-?}"
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
[ -n "$LAN_URL" ] && echo "Dashboard on your network: $LAN_URL" || echo "No dashboard address given, so the network check is skipped."
ask "Start?" y || exit 0

# A port and token for the app's test listener, kept between runs so a pasted snippet stays valid.
STATE="$KIT/state.env"
PORT=""
TOKEN=""
[ -f "$STATE" ] && . "$STATE"
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

say "Installing build 1"
install_build 1
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
    note statusline.settings 4 "Your Claude Code settings" skipped "settings.json didn't parse as JSON."
  else
    [ -n "$CURRENT" ] && echo "Your status line command now: $CURRENT" || echo "You have no status line command now."
    echo "First, a self-test with made-up numbers (your settings aren't touched):"
    TEST_SNIPPET=$(printf '%s' 'cat >/dev/null; printf STATUS-OK' | api POST /snippet -H 'X-Snippet-Purpose: test' --data-binary @-)
    if [ -z "$TEST_SNIPPET" ]; then
      echo "The app didn't build a snippet."
    else
      printf '%s\n' "$TEST_SNIPPET" > "$OUT/snippet-selftest.txt"
      selftest "$TEST_SNIPPET" /bin/sh "sh"
      selftest "$TEST_SNIPPET" /bin/zsh "zsh"
      selftest "$(printf '%s' "$TEST_SNIPPET" | sed 's#/usr/bin/jq#/nonexistent/jq#g')" /bin/sh "sed-fallback"
      [ -x /usr/bin/jq ] && note statusline.jq 4 "/usr/bin/jq on this Mac" info "$(/usr/bin/jq --version 2>&1)" \
        || note statusline.jq 4 "/usr/bin/jq on this Mac" info "not installed (the snippet uses sed)"
    fi
    SNIPPET=$(printf '%s' "$CURRENT" | api POST /snippet --data-binary @-)
    if [ -z "$SNIPPET" ]; then
      echo "The app didn't build the snippet; skipping."
    elif ask "Switch your Claude Code status line to the test snippet now? Your settings are backed up first and put back right after." y; then
      mkdir -p "$HOME/.claude"
      if [ -f "$SETTINGS" ]; then
        SETTINGS_EXISTED=1
        SETTINGS_MODE=$(stat -f %Lp "$SETTINGS")
        cp -p "$SETTINGS" "$OUT/settings.json.backup"
      fi
      osascript -l JavaScript "$KIT/settings.js" get "$SETTINGS" > "$OUT/statusline-before.json"
      STATUS_OLD="$OUT/statusline-before.json"
      STATUS_BACKUP="$OUT/settings.json.backup"
      printf '%s' "$SNIPPET" > "$OUT/snippet.txt"
      if osascript -l JavaScript "$KIT/settings.js" set "$SETTINGS" "$OUT/snippet.txt" >/dev/null; then
        [ -n "$SETTINGS_MODE" ] && chmod "$SETTINGS_MODE" "$SETTINGS"
        cp -p "$SETTINGS" "$OUT/settings.json.written"
        STATUS_WRITTEN="$OUT/settings.json.written"
        echo
        echo "Done. Now, in any Claude Code session (a new one is fine: cd ~ && claude), send a short"
        echo "message such as \"hi\" and wait for the reply. Check that your status line looks as it did."
        echo "Waiting for a reading from Claude Code (press Enter to stop waiting)..."
        BEFORE=$(state_value claude)
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
      fi
      restore_status_line
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
  save update
fi
quit_app
kill "$SAMPLER" 2>/dev/null
SAMPLER=""

say "Collecting logs"
/usr/bin/log show --style ndjson --start "$LOG_START" --predicate 'subsystem == "AIUsageStoreTest"' > "$OUT/unified-log.ndjson" 2>/dev/null
/usr/bin/log show --style compact --start "$LOG_START" \
  --predicate 'eventMessage CONTAINS[c] "deny" AND (eventMessage CONTAINS "codex-app-server" OR eventMessage CONTAINS "AI Usage Store Test" OR eventMessage CONTAINS "StoreTestWidget")' \
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
