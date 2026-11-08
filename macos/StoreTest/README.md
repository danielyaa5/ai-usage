# AI Usage Store Test

A throwaway Mac app that checks, on a real Mac, the four things a Mac App Store version of AI Usage
would depend on. It is not the product and is never submitted. Each check runs inside the App
Sandbox, the way a store app would.

1. **ChatGPT limits through the bundled Codex.** OpenAI's `codex-app-server` (from a Codex release,
   checked against its SHA-256 and OpenAI's signature) sits next to the app's executable and runs in
   the app's sandbox. The app signs in with ChatGPT in a private browser window
   (`ASWebAuthenticationSession`, with Codex's own login server on 127.0.0.1 taking the callback; if
   that window doesn't open, it copies the sign-in link for you to paste into a private window),
   reads the limits with `account/rateLimits/read`, and watches for a minute which servers Codex
   contacts. Codex's proxy variables point at a logging proxy in the app, which notes each host and
   passes the encrypted bytes through unread. It connects only to auth.openai.com and chatgpt.com,
   and refuses anything else Codex asks for, noting it all the same. Codex runs with plugins, update
   checks, analytics, feedback, telemetry, history, remote control and the model download turned
   off, and `--strict-config`. Its sign-in is the test's own, kept in the app's container; the test
   signs out after the update run (if the run stops before then, the runner says so, and deleting
   the app's containers removes the sign-in). If another Codex sign-in is open on the Mac (something
   already listens on 127.0.0.1:1455), the test doesn't start one, because Codex would cancel the
   other.
2. **Plain HTTP to this Mac and the local network.** The app and its widget read
   `http://127.0.0.1`, `http://localhost` and, if given, an AI Usage dashboard on another Mac, with
   only the `NSAllowsLocalNetworking` exception to App Transport Security. It records whether macOS
   asks about the local network, and checks that ATS still refuses plain HTTP to the internet.
3. **Reading `~/.claude` and `~/.codex`.** You pick each folder in the Open panel; the app keeps a
   read-only security-scoped bookmark and reads it again after a relaunch and after an update. It
   counts entries and reads 64 bytes of one log file, and keeps none of it.
4. **Claude limits from the status line.** Claude Code runs a `statusLine` command with a line of
   JSON on its input. The snippet (`../ProviderSupport/StatusLineSnippet.swift`) sends only `rate_limits` from it to
   the app on 127.0.0.1 in the background, then runs your own status line command with the full
   input, so your status line looks the same.

The runner installs build 1, then build 2 (a higher build number) over it the way an update would.
Build 1 signs the Codex helper without the hardened runtime and build 2 with it, so the update run
also shows whether Codex works hardened.

What the test keeps: check results, counts, host names, timings and Codex's log lines with anything
that mentions credentials left out, and Codex's errors without the HTTP replies they quote, with
account and user IDs and addresses masked. It never keeps prompts, file contents, tokens or email
addresses. The results do name this Mac's user (in file paths) and the signing team and bundle IDs,
so look through them before sharing them.

## Build

On a Mac with Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (no certificate needed):

```sh
macos/StoreTest/scripts/build.sh     # -> macos/StoreTest/build.noindex/kit/
```

It uses `AI_USAGE_BUNDLE_PREFIX` from the environment or `macos/Local.xcconfig`, and builds unsigned.

## Sign and run

Copy the `kit` folder to the Mac you'll test on, then in Terminal there (not over SSH, where
`codesign` usually can't use the login keychain):

```sh
./run.sh         # or ./run.sh http://my-mac.local:8796/api/widget for the local network checks
```

`run.sh` first runs `sign.sh` when the builds aren't signed yet, which signs them with your Apple
Development certificate. With certificates from more than one team, put `DEVELOPMENT_TEAM=<team ID>`
in a `local.env` file in the kit (it can also hold `LAN_URL=` for the network checks).

`run.sh` takes about ten minutes and asks before each step that needs you. It installs
`/Applications/AI Usage Store Test.app`, and, only if you agree, switches the `statusLine` setting in
`~/.claude/settings.json` to the snippet for a minute: it backs the file up first (in
`settings-backup/`, which it deletes once the setting is checked back) and puts the setting back
afterwards, also if the script is stopped. Everything it gathers goes to
`results/<time>/` next to it, including the unified log, sandbox denials and any crash reports.

Claude Code passes subscription limits to the status line only after Anthropic has replied, so the
status line check needs one message answered in a Claude Code session while the script waits. The
script can open a Terminal window with Claude Code for that, in an empty folder of the kit
(`work.noindex/claude-session`): in your home folder, Claude Code's file index would walk Desktop,
Documents and other apps' data, and macOS could ask about those, which has nothing to do with the
test. If you didn't answer a message, the check is recorded as not tested rather than failed. To
repeat only that check later, with the test app already installed (or build 2, if it isn't):

```sh
./run.sh --status-line
```

That rerun brings its own terminal window back in front of the app's and asks everything there; the
app's steps 1 to 3 aren't needed. It doesn't sign out of ChatGPT, so if you sign in in the app during
it anyway, that sign-in stays in the app's container until the next full run or until you delete the
containers.

Afterwards, remove the Store Test widget, delete the app, and delete its containers: the app's and
the widget's in `~/Library/Containers/` (named after their bundle IDs, starting
`<prefix>.AIUsageStoreTest`) and the shared one in `~/Library/Group Containers/` (your team ID, a
dot, then the app's bundle ID).
