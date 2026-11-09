# AI Usage for Mac

The menu bar app and desktop widgets work on Apple silicon Macs running macOS 14 or later. The default source is **This Mac**. The app bundles its ChatGPT helper. End users do not need Xcode, Python, a separate server, or a system installation of Codex to sign in and see ChatGPT limits.

## First launch

1. Open AI Usage and choose the tools you use. The guide walks through one tool at a time. You can skip any connection, try sample data, or finish later. If you close setup partway through, it resumes where you left off.
2. For each tool, **Connect history…** lets you choose the folder that holds usage recorded on this Mac. The picker shows hidden folders. Each tool also offers a separate way to see remaining quota. You can connect either or both.
3. In **Add your widget**, preview **Plan limits** or **Usage totals**. Control-click your desktop, choose **Edit Widgets**, and search for **AI Usage**. Add **AI plan limits** for remaining quota or **AI usage totals** for recorded activity. A medium or larger plan widget can show one provider’s limits and seven-day totals.
4. After setup, open **Settings** from the menu bar. **Connections** shows what each tool is sharing. **Guided setup** reopens the walkthrough. The Dock icon appears while the setup or Settings window is open. Closing the window keeps refresh running. **Advanced → Open at login** is optional.

In **Settings → Menu Bar**, keep the gauge on its own or replace it with a meter for Claude, Codex / ChatGPT, or Google Antigravity. Each meter shows that provider’s lowest current quota percentage. A dashed meter means there is no current reading. Click the gauge or a meter to open the full limits panel.

| Source | What becomes available |
|---|---|
| Claude Code history (`.claude`) | Requests, tokens and estimated API value from recorded assistant usage |
| Codex history (`.codex`) | Recorded requests and tokens in current and archived sessions, plus limit windows when a session includes them |
| Antigravity history (`.gemini`) | Recorded usage in the IDE and CLI conversation databases. Only checkpointed metadata is read. |
| Sign in with ChatGPT | Account-wide limit readings directly from OpenAI, including on a Mac with no Codex history |
| Claude Desktop limits | Choose **Connect Claude Desktop…**, then **Allow** in the folder picker. The widget shows the most recent five-hour or weekly percentage Claude saved on this Mac, with its original observation time. **Open Claude usage** shows current limits and reset times. |
| Claude Code in Terminal | If you use the interactive terminal CLI, expand **I use Claude Code in Terminal** and paste its setup request into that terminal session. Approve the change if asked, then send a message there. The desktop Code tab uses the Desktop connection above. |

History covers activity recorded on this Mac. If there are no requests yet, complete a request in the connected tool, let it save and click **Refresh now**. Signing in for limits alone does not supply historic token totals. An API-equivalent estimate uses the bundled price table and excludes requests whose model has no listed price.

## Claude Desktop quota

This connection reads only `plan-usage-history.json` in the Claude folder you authorize. AI Usage checks about every five minutes. **Check for a new reading** rereads the same file. Claude Desktop controls when it saves samples. A sample can include either or both windows and contains no reset time. The widget shows the percentage left from the latest single sample, including its age.

If the saved reading is old or missing, **Open Claude usage** takes you to the account’s Usage page. **Enter current percentages…** lets you record the percentages shown as used there. The widget marks these readings as entered until Claude Desktop saves a newer sample. Disconnecting Desktop removes this app’s folder grant and any entered reading. A previously configured terminal connection resumes when Desktop is disconnected.

## Google Antigravity quota

In the guide or in **Settings → Google Antigravity**, click **Connect Google quota** under **Remaining quota**. AI Usage reuses permission for Antigravity’s history folder if you have already connected it. Otherwise, macOS opens its folder picker at Antigravity’s **daemon** folder. Click **Allow** to grant read-only access. Connect opens the installed Antigravity desktop app if needed. Sign in to Antigravity and keep it running.

Add **AI plan limits** to your desktop and choose **Google AI (Antigravity)** to see the remaining percentages and reset times. The menu bar app checks about every five minutes, including with its settings window closed. If quota is unavailable, check that Antigravity is up to date and signed in, then click **Refresh now**. The same **This Mac** source can show Google quota alongside the history and other accounts you have connected. **Disconnect** turns off the quota reading independently of usage history.

If you previously used **Dashboard** for Google quota, **Advanced → Use Google quota on this Mac** switches to the local reader after it connects. Your saved dashboard address is retained for future use. An optional [full dashboard](../README.md#install) also offers a per-model usage table.

## Other sources

**Advanced → Widget data** lets you change sources. **Demo** uses fictional data and works offline. **Dashboard** reads an AI Usage server at an address you supply, including a path such as `my-server.local:8088/ai-usage/`. This mode also supports live Antigravity limits and server-side background job attribution. Existing installations with a saved dashboard keep that selection when upgraded.

The app refreshes on a five-minute timer. Widgets read shared summaries in the app group. In local mode only the app holds folder permissions and runs provider connections. When the app has been closed long enough for a reading to age, open it from the widget to refresh. In dashboard mode a widget can also refresh directly from the server. macOS schedules timeline redraws.

## Build

Use Xcode and XcodeGen. Put your development team and bundle prefix in the untracked `macos/Local.xcconfig`:

```
DEVELOPMENT_TEAM = ABCDE12345
AI_USAGE_BUNDLE_PREFIX = com.example.you
```

From the repository root, run `macos/scripts/build.sh` and `macos/scripts/install.sh` for a local Apple Development build. The build downloads a pinned, checksum-verified, Apple-silicon Codex helper from OpenAI and checks its original signature before signing it for the app sandbox. The helper ships inside the app. Its notices are in the app resources.

For an isolated first-run test, build with `macos/scripts/build.sh --fresh-install`, then copy **AI Usage Fresh Install.app** from `macos/build.noindex/FreshInstall` to Applications and open it. It has its own folder permissions, preferences, widget data and links. Select **AI Usage Fresh Install** in the widget gallery. The first-run window appears the first time you launch that identity.

For the private Claude quota trial, `macos/scripts/build.sh --setup-test` updates **AI Usage Setup Test** and preserves that app’s connections. To start with a separate Claude sign-in and a new setup, use `macos/scripts/build.sh --claude-fresh-test` and open **AI Usage Claude Fresh Test**. Each copy has its own widgets. In guided setup, choose **Claude**, then **Connect Claude**. A new user signs in with Claude in their browser. Local history is optional.

These two development builds copy the build Mac’s original, signature-verified Claude Code executable into the test app. The trial was tested with Claude Code 2.1.319. It uses the experimental structured usage check and skips transcript scanning. The regular app and App Store archive exclude automatic Claude quota and its helper.

Run `macos/release/archive.sh` to archive, export and verify a local Mac App Store installer package. It uses Xcode’s configured developer account. See the [release files](release/README.md) and [privacy policy](../docs/privacy.md).

## Verify

Run `swift test --package-path macos` and `python3 -m unittest discover -s tests -t .`. The Swift tests include clean-source selection, legacy dashboard migration, local reading and cache isolation, token deduplication, partial log writes, read-only Antigravity accounting, and limits without history.

Run `python3 macos/Tests/test_claude_reporter.py "/Applications/AI Usage.app"` to check that the installed Claude reporter preserves an existing status line, including one that closes its input immediately.

The app supports `--refresh-once`, `--set-server ADDRESS`, and `--render-previews FOLDER --sample`. For rendering, choose a folder inside the signed app’s own sandbox container. `--render-store-assets FOLDER` renders the listing artwork from fictional data and a clean setup view. Neither rendering command installs widgets. Use a placed widget to check delivery and freshness.
