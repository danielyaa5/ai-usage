#!/bin/bash
# Runs the AI Usage store test on this Mac (see README.md). In a kit folder made by build.sh (it
# runs sign.sh first when the builds aren't signed yet):
#
#   ./run.sh [DASHBOARD_URL]
#   ./run.sh --status-line
#
# DASHBOARD_URL is an AI Usage dashboard on another Mac on your network, such as
# http://my-mac.local:8796/api/widget, for the local network checks. It can also come from a
# local.env file next to this script (LAN_URL=...).
#
# It installs build 1 in /Applications and opens it for the interactive checks, then checks the
# Claude Code status line snippet with you (it switches your status line for a minute, if you agree,
# and puts it back), relaunches the app, installs build 2 over it the way an update would, and
# collects everything in results/<time>/ next to this script.
#
# --status-line repeats only that status line check (step 4), with the test app already installed
# (or build 2, if it isn't). It takes a few minutes.
set -uo pipefail

# It asks you questions, so it needs a terminal: without one, every answer would be a guess.
if ! { : </dev/tty; } 2>/dev/null; then
  echo "Run this in Terminal: it asks you questions as it goes." >&2
  exit 1
fi

MODE=full
case "${1:-}" in
  --status-line) MODE=status-line; shift ;;
  -*) echo "Unknown option $1. Usage: ./run.sh [DASHBOARD_URL] or ./run.sh --status-line" >&2; exit 1 ;;
esac

KIT=$(cd "$(dirname "$0")" && pwd)
APP_NAME="AI Usage Store Test"
APP="/Applications/$APP_NAME.app"
HELPER="$APP/Contents/MacOS/codex-app-server"
# The app is found by its executable's path, so only the copy in /Applications counts, not one
# running from a build folder.
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

# With no default (""), an empty line asks again, so an Enter pressed earlier can't answer the question.
# bash 3.2 can't throw away what was typed ahead (read -t takes whole seconds, and -t 0 waits).
ask() {  # ask QUESTION y|n|"" -> status 0 for yes
  local reply hint="[y/n]"
  [ "$2" = y ] && hint="[Y/n]"
  [ "$2" = n ] && hint="[y/N]"
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
  local zip="$KIT/signed-$1.zip" existing work
  [ -f "$zip" ] || { echo "Missing $zip: run sign.sh first."; exit 1; }
  quit_app
  if [ -d "$APP" ]; then
    existing=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)
    case "$existing" in
      *.AIUsageStoreTest) ;;
      *) echo "$APP belongs to another app ($existing); not replacing it."; exit 1 ;;
    esac
  fi
  # Unpacked next to this script and swapped in by renaming, so a stopped run can't leave half an app
  # in /Applications.
  mkdir -p "$KIT/work.noindex"
  rm -rf "$KIT"/work.noindex/install.*
  work=$(mktemp -d "$KIT/work.noindex/install.XXXXXX") || { echo "Couldn't unpack build $1."; exit 1; }
  if ! ditto --noqtn -x -k "$zip" "$work" || [ ! -d "$work/$APP_NAME.app" ]; then
    echo "Couldn't unpack build $1."
    rm -rf "$work"
    exit 1
  fi
  if [ -d "$APP" ] && ! mv "$APP" "$work/old.app"; then
    echo "Couldn't move the installed test app aside. If macOS said Terminal was prevented from"
    echo "modifying apps, allow Terminal in System Settings > Privacy & Security > App Management."
    rm -rf "$work"
    exit 1
  fi
  if ! mv "$work/$APP_NAME.app" "$APP"; then
    echo "Couldn't install into /Applications."
    rm -rf "$work"
    exit 1
  fi
  rm -rf "$work"
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
BACKUP_PENDING=0    # 1 while a backup exists that no switch has taken over yet: the cleanup deletes it
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
  BACKUP_PENDING=1
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
    # Done, so a stop from here on only has to finish deleting the backup, not restore from half of it.
    # BACKUP_PENDING goes first: a stop between the two still restores from the whole backup.
    BACKUP_PENDING=1
    SWITCHED=0
    rm -rf "$BACKUP_DIR"
    rmdir "$KIT/settings-backup" 2>/dev/null || true
    BACKUP_PENDING=0
  else
    BACKUP_PENDING=0   # kept on purpose: the warning points to it
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
OPENED=0       # set once the script has opened a Terminal window with Claude Code
QUIT_HINTED=0  # set once you've been told you can quit that Claude Code session

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
  # A backup made for a switch that never started holds a whole copy of settings.json: don't leave it.
  if [ "$BACKUP_PENDING" = 1 ]; then
    rm -rf "$BACKUP_DIR"
    rmdir "$KIT/settings-backup" 2>/dev/null || true
  fi
  quit_app
  if [ "$INSTALLED" = 1 ] && [ "$SIGNED_OUT" = 0 ]; then
    echo "The test stopped before its last step, where it signs out of ChatGPT, so its own sign-in may"
    echo "still be in the app's container. Deleting the app's containers (see README.md) removes it."
  fi
  if [ "$OPENED" = 1 ] && [ "$QUIT_HINTED" = 0 ]; then
    echo "The Claude Code window this test opened is still open; type /exit in it to quit."
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

installed_test_app() {  # status 0 when /Applications holds this test app
  [ -d "$APP" ] || return 1
  case "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null)" in
    *.AIUsageStoreTest) return 0 ;;
  esac
  return 1
}

sign_if_needed() {
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
}

# Claude Code's own path, so the window opened for it doesn't depend on your shell's aliases.
find_claude() {
  local candidate
  for candidate in "$(command -v claude 2>/dev/null)" "$HOME/.local/bin/claude" "$HOME/.claude/local/claude" \
      /opt/homebrew/bin/claude /usr/local/bin/claude; do
    if [ -n "$candidate" ] && [ -f "$candidate" ] && [ -x "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

# The terminal app this script runs in, to bring back in front of the test app's window: the app opens
# on top, and its Continue button can't raise a terminal. Over SSH there's nothing to raise.
terminal_app_id() {
  [ -n "${SSH_CONNECTION:-}${SSH_TTY:-}" ] && return 1
  case "${TERM_PROGRAM:-}" in
    Apple_Terminal) printf 'com.apple.Terminal' ;;
    iTerm.app) printf 'com.googlecode.iterm2' ;;
    *) [ -n "${__CFBundleIdentifier:-}" ] || return 1; printf '%s' "$__CFBundleIdentifier" ;;
  esac
}

front_terminal() {
  local id
  id=$(terminal_app_id) || return 0
  sleep 1   # after the app has finished coming to the front
  open -b "$id" >/dev/null 2>&1 || true
  printf '\a' >/dev/tty 2>/dev/null || true
}

# Claude Code runs in an empty folder of the kit's, not your home folder, where reading the folder
# could make macOS ask about Desktop, Documents or Downloads, which has nothing to do with this test.
CLAUDE_SESSION_DIR="$KIT/work.noindex/claude-session"

claude_env_prefix() {  # CLAUDE_CONFIG_DIR=... when it's set here, so Claude Code reads the settings this test switched
  [ -n "${CLAUDE_CONFIG_DIR:-}" ] && printf 'CLAUDE_CONFIG_DIR=%q ' "$CLAUDE_CONFIG_DIR"
  return 0
}

open_claude_session() {  # a new Terminal window with Claude Code; the launcher file deletes itself
  local claude launcher="$KIT/work.noindex/Claude Code for the store test.command"
  claude=$(find_claude) || return 1
  mkdir -p "$CLAUDE_SESSION_DIR" || return 1
  printf '#!/bin/bash\n# Opened by run.sh for the status line check.\nrm -f -- "$0"\ncd %q && %sexec %q\n' \
    "$CLAUDE_SESSION_DIR" "$(claude_env_prefix)" "$claude" > "$launcher" || return 1
  if chmod 700 "$launcher" && open -a Terminal "$launcher"; then
    OPENED=1
    return 0
  fi
  rm -f "$launcher"
  return 1
}

# Claude Code's trust question can start with "No, exit" selected, so Return alone would quit it.
TRUST_HINT='If Claude Code asks whether you trust this folder, use the arrow keys to pick "Yes, I trust this folder" before pressing Return.'

start_window() {  # opens the window, or explains how to start Claude Code by hand
  if open_claude_session; then
    echo "In the new window, which opens in an empty folder of this kit:"
    echo "$TRUST_HINT"
    echo "Then type a short message such as \"hi\", press Return, wait for the reply, and come back here."
  else
    manual_steps "Couldn't open it. Start Claude Code yourself in another Terminal tab:"
  fi
}

start_claude() {
  if find_claude >/dev/null && ask "Open a new Terminal window with Claude Code for this?" ""; then
    start_window
  else
    manual_steps "Start Claude Code in another Terminal tab:"
  fi
}

manual_steps() {  # manual_steps FIRST_LINE: how to start Claude Code by hand
  mkdir -p "$CLAUDE_SESSION_DIR" 2>/dev/null
  echo "$1"
  printf '  cd %q && %sclaude\n' "$CLAUDE_SESSION_DIR" "$(claude_env_prefix)"
  echo "$TRUST_HINT"
  echo "Then send a short message such as \"hi\" and wait for the reply."
}

# Waits up to 10 minutes for a reading from Claude Code's status line, reminding you every minute.
# Status 0 when one has arrived since CLAUDE_BEFORE, also one that came while you were answering a question.
CLAUDE_BEFORE=0
WAITED=0
got_reading() { local now; now=$(state_value claude); [ "${now:-0}" -gt "${CLAUDE_BEFORE:-0}" ] 2>/dev/null; }

wait_for_reading() {
  local waited=0 started=$SECONDS
  echo "Waiting for a reading from Claude Code (press Enter to stop waiting)..."
  while [ "$waited" -lt 600 ]; do
    if got_reading; then
      WAITED=$((WAITED + SECONDS - started))
      echo "Got a reading from Claude Code."
      return 0
    fi
    if ! app_running; then
      WAITED=$((WAITED + SECONDS - started))
      echo "The test app isn't running any more, so no reading can arrive."
      return 1
    fi
    # In a subshell: on bash 3.2, a Ctrl-C during read -t can leave its alarm set to go off in the cleanup.
    if ( IFS= read -r -t 5 _ </dev/tty ); then break; fi
    waited=$((waited + 5))
    if [ $((waited % 60)) -eq 0 ] && [ "$waited" -lt 600 ]; then
      echo "  Still waiting after $((waited / 60)) min: send Claude Code a message and wait for its reply."
    fi
  done
  WAITED=$((WAITED + SECONDS - started))
  if got_reading; then
    echo "Got a reading from Claude Code."
    return 0
  fi
  return 1
}

status_line_step() {  # status_line_step PHASE: step 4, with the app's results saved as PHASE
  local phase=$1 current read_status test_snippet snippet got=0 sent=0 what why
  say "Step 4: your Claude Code status line"
  if ! app_running; then
    echo "The app isn't running any more; skipping the status line check."
    return
  fi
  current=$(osascript -l JavaScript "$KIT/settings.js" command "$SETTINGS" 2>>"$OUT/runner-errors.txt")
  read_status=$?
  if [ "$read_status" -ne 0 ]; then
    echo "Couldn't read $SETTINGS as JSON, so the status line part is skipped."
    note statusline.settings 4 "Your Claude Code settings" skipped "settings.json couldn't be read as JSON."
    return
  fi
  if [ -n "$current" ]; then
    # Shown on screen only, so your command stays out of the results.
    printf 'Your status line command now: %s\n' "$current" >/dev/tty
    echo "You have a status line command (${#current} characters)."
  else
    echo "You have no status line command now."
  fi
  echo "First, a self-test with made-up numbers (your settings aren't touched):"
  test_snippet=$(printf '%s' 'printf "STATUS-OK "; cksum' | api POST /snippet -H 'X-Snippet-Purpose: test' --data-binary @-)
  if ! is_snippet "$test_snippet"; then
    echo "The app didn't build a snippet."
    note statusline.selftest 4 "Snippet self-test" failed "The app didn't build a snippet."
  else
    printf '%s\n' "$test_snippet" | sed "s/$TOKEN/TOKEN/g" > "$OUT/snippet-selftest.txt"
    # Every reading in this time is the self-test's, even one the snippet got wrong.
    api POST /selftest --data-binary start >/dev/null 2>&1 || true
    selftest "$test_snippet" /bin/sh "sh"
    selftest "$test_snippet" /bin/zsh "zsh"
    selftest "$(printf '%s' "$test_snippet" | sed 's#/usr/bin/jq#/nonexistent/jq#g')" /bin/sh "sed-fallback"
    api POST /selftest --data-binary stop >/dev/null 2>&1 || true
    [ -x /usr/bin/jq ] && note statusline.jq 4 "/usr/bin/jq on this Mac" info "$(/usr/bin/jq --version 2>&1)" \
      || note statusline.jq 4 "/usr/bin/jq on this Mac" info "not installed (the snippet uses sed)"
  fi
  save "$phase"
  snippet=$(printf '%s' "$current" | api POST /snippet --data-binary @-)
  if ! is_snippet "$snippet"; then
    echo "The app didn't build the snippet; skipping."
    note statusline.switch 4 "Status line switched for the test" failed "The app didn't build the snippet."
    return
  fi
  if ! ask "Switch your Claude Code status line to the test snippet now? Your settings are backed up first and put back right after." ""; then
    note statusline.switch 4 "Status line switched for the test" skipped "You chose not to."
    return
  fi
  if ! back_up_settings "$snippet"; then
    echo "$SKIP_REASON So the switch is skipped, and your settings weren't touched."
    note statusline.switch 4 "Status line switched for the test" skipped "$SKIP_REASON"
    return
  fi
  SWITCHED=1
  BACKUP_PENDING=0
  # settings.js writes settings.json.written, the exact copy, before it changes settings.json.
  if ! osascript -l JavaScript "$KIT/settings.js" set "$SETTINGS_FILE" "$BACKUP_DIR/snippet.txt" "$BACKUP_DIR/settings.json.written" >/dev/null 2>>"$OUT/runner-errors.txt"; then
    echo "Couldn't write $SETTINGS; skipping."
    note statusline.switch 4 "Status line switched for the test" failed "settings.json couldn't be written."
    restore_status_line
    return
  fi
  [ -n "$SETTINGS_MODE" ] && chmod "$SETTINGS_MODE" "$SETTINGS_FILE"
  CLAUDE_BEFORE=$(state_value claude)
  WAITED=0
  echo
  echo "Switched. Now Claude Code has to answer one message: it passes your subscription limits to the"
  echo "status line only after Anthropic has replied."
  start_claude
  while true; do
    if wait_for_reading; then
      got=1
      break
    fi
    app_running || break
    if ask "No reading yet. Did you send Claude Code a message and get its reply while this waited?" ""; then
      sent=1
      break
    fi
    got_reading && break   # it came while you were answering
    ask "Wait again? Send Claude Code a message first, then answer y." "" || break
    got_reading && continue
    if [ "$OPENED" = 1 ]; then
      if ask "Open a new Claude Code window? (Answer n if the one from before is still open.)" ""; then
        start_window
      fi
    else
      manual_steps "If Claude Code isn't running, start it in another Terminal tab:"
    fi
  done
  # A reading can also arrive while you answer the questions above, or a moment after a reply.
  if [ "$got" = 0 ] && [ "$sent" = 1 ]; then
    echo "Checking for a reading a few more seconds..."
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      got_reading && break
      app_running || break
      sleep 1
    done
  fi
  if [ "$got" = 0 ] && got_reading; then
    got=1
    echo "Got a reading from Claude Code."
  fi
  why=""
  if [ "$got" = 0 ]; then
    if ! app_running; then
      why="The test app quit during the check."
      note statusline.claude 4 "Readings from Claude Code's status line" failed "The test app quit during the wait ($WAITED s), so no reading could arrive. If it crashed, the report is in crashes/."
    elif [ "$sent" = 1 ]; then
      note statusline.claude 4 "Readings from Claude Code's status line" failed "No reading arrived, although you sent Claude Code a message and got its reply (waited $WAITED s)."
    else
      why="Claude Code didn't answer a message during the check."
      note statusline.claude 4 "Readings from Claude Code's status line" skipped "Not tested: Claude Code didn't answer a message while this waited ($WAITED s)."
    fi
  fi
  save "$phase"
  if [ -z "$why" ]; then
    if [ -n "$current" ]; then
      if ask "Did your status line in Claude Code look the same as before?" ""; then
        note statusline.looks-same 4 "Your status line looked the same" passed "You said yes."
      else
        note statusline.looks-same 4 "Your status line looked the same" failed "You said no."
      fi
    elif ask "Did Claude Code work as usual? (With no status line of your own, its status line row stays empty.)" ""; then
      note statusline.looks-same 4 "Claude Code worked as usual with the snippet" passed "You said yes."
    else
      note statusline.looks-same 4 "Claude Code worked as usual with the snippet" failed "You said no."
    fi
    if ask "Apart from this script's questions and Claude Code asking whether you trust the folder, did anything ask you for permission?" ""; then
      printf 'What asked, in a few words? (It goes in the results.) '
      IFS= read -r what </dev/tty || what=""
      # At most 200 characters, and never half of one, which would make the note invalid JSON.
      what=$(printf '%s' "${what:0:200}" | iconv -c -f UTF-8 -t UTF-8 2>/dev/null)
      [ -n "$what" ] || what="(no description)"
      note statusline.prompts 4 "No prompts during the hand-off" failed "You saw a prompt: $what"
    else
      note statusline.prompts 4 "No prompts during the hand-off" passed "You saw none."
    fi
  else
    note statusline.looks-same 4 "Your status line looked the same" skipped "$why"
    note statusline.prompts 4 "No prompts during the hand-off" skipped "$why"
  fi
  if [ "$OPENED" = 1 ] || [ "$got" = 1 ] || [ "$sent" = 1 ]; then
    echo "You can quit that Claude Code session now (type /exit in it)."
    QUIT_HINTED=1
  fi
  restore_status_line
}

collect_logs() {
  say "Collecting logs"
  /usr/bin/log show --style ndjson --start "$LOG_START" --predicate 'subsystem == "AIUsageStoreTest"' > "$OUT/unified-log.ndjson" 2>/dev/null
  /usr/bin/log show --style compact --start "$LOG_START" \
    --predicate 'eventMessage CONTAINS[c] "deny" AND (eventMessage CONTAINS "codex-app-serv" OR eventMessage CONTAINS "AI Usage Store" OR eventMessage CONTAINS "StoreTestWidget")' \
    > "$OUT/sandbox-denials.txt" 2>/dev/null   # the kernel's messages can cut a process name short
  /usr/bin/log show --style compact --start "$LOG_START" --predicate 'process == "nehelper"' 2>/dev/null |
    grep -i 'AIUsageStoreTest\|Store Test\|StoreTestWidget' > "$OUT/local-network.txt"
  mkdir -p "$OUT/crashes"
  find "$HOME/Library/Logs/DiagnosticReports" -maxdepth 1 -newer "$OUT/system.txt" \
    \( -name 'codex-app-serv*' -o -name 'AI Usage Store*' -o -name 'StoreTestWidget*' \) \
    -exec cp {} "$OUT/crashes/" \; 2>/dev/null
  pluginkit -m -v -i "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist").Widget" > "$OUT/pluginkit.txt" 2>&1
}

# ---------------------------------------------------------------------------------------------------

if [ "$MODE" = status-line ]; then
  say "AI Usage store test: the status line check again"
  cat <<EOF
This repeats only step 4, your Claude Code status line, with the test app in /Applications (it
installs build 2 first if the app isn't there). A few minutes, most of it one message to Claude Code.
Results go to $OUT
EOF
else
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
{ sw_vers; uname -m; echo "port $PORT"; echo "mode $MODE"; cat "$KIT/BUILD-INFO.txt" 2>/dev/null; } > "$OUT/system.txt"

if [ "$MODE" = status-line ]; then
  if ! installed_test_app; then
    sign_if_needed
    say "Installing build 2"
    install_build 2
  fi
  say "Opening the test app"
  launch first || exit 1
  front_terminal
  echo "The test app's window is open behind this one. Leave it open until this script says it's done,"
  echo "but don't use it this time: skip its steps 1 to 3 and its Continue button. Everything for this"
  echo "check happens here, in this window."
  status_line_step statusline
  save statusline
  quit_app
else
  sign_if_needed

  say "Installing build 1"
  install_build 1
  INSTALLED=1
  sampler &
  SAMPLER=$!

  say "Steps 1 to 3 are in the app window"
  launch first || exit 1
  echo "Work through steps 1 to 3 in the app window, then click Continue in Terminal there."
  echo "Leave the app's window open until this script says it's done: closing it quits the app, and the"
  echo "steps after it are skipped. The app opens twice more by itself later; leave those windows open too."
  echo "(Or press Enter here to move on.)"
  while app_running; do
    if [ "$(state_value handoff)" = 1 ]; then
      front_terminal
      break
    fi
    # In a subshell: on bash 3.2, a Ctrl-C during read -t can leave its alarm set to go off in the cleanup.
    if ( IFS= read -r -t 5 _ </dev/tty ); then break; fi
    save first
  done
  save first

  status_line_step first
  if app_running && [ "$(state_value codex)" = busy ]; then
    echo "Waiting for the ChatGPT check in the app to finish..."
    for _ in $(seq 1 100); do
      [ "$(state_value codex)" = busy ] || break
      sleep 3
    done
  fi
  save first
  quit_app

  say "Relaunching the app (it checks by itself; leave its window open)"
  if launch relaunch; then
    for _ in $(seq 1 60); do
      [ "$(state_value done)" = 1 ] && break
      sleep 3
    done
    save relaunch
  fi
  quit_app

  say "Installing build 2 over it, as an update would, and checking again (leave its window open)"
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
fi

collect_logs

for phase in first relaunch update statusline; do
  [ -f "$OUT/$phase-summary.txt" ] && { cat "$OUT/$phase-summary.txt"; echo; }
done > "$OUT/summary.txt"
if [ "$MODE" = status-line ] && [ -f "$OUT/runner-notes.txt" ]; then
  { echo "What this script recorded:"; sed 's/^/  /' "$OUT/runner-notes.txt"; } >> "$OUT/summary.txt"
fi
say "Summary"
cat "$OUT/summary.txt"
echo
echo "All done. The results are in $OUT"
if [ "$MODE" = status-line ]; then
  # Only the full run's last step signs the test out of ChatGPT.
  if grep -q '"id":"codex.login","status":"passed"' "$OUT/statusline.json" 2>/dev/null; then
    echo "You signed in to ChatGPT in the test app this time. That sign-in stays in the app's container"
    echo "until the next full run, which signs out first, or until you delete the app's containers (see"
    echo "README.md)."
  fi
  echo "Reply \"done\" in the thread."
else
  echo "You can remove the Store Test widget now. Reply \"done\" in the thread."
fi
