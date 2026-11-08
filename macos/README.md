# AI Usage for Mac

The menu bar app and desktop widgets work on Apple silicon Macs running macOS 14 or later. The default source is **This Mac**. The app bundles its ChatGPT helper. End users do not need Xcode, Python, a separate server, or a system installation of Codex to sign in and see ChatGPT limits.

## First launch

1. Open AI Usage. In **Sources → This Mac**, click **Connect…** beside a tool you use. Select its folder in the macOS picker. Hidden folders are visible. A custom tool folder is also supported when it contains the expected history directories.
2. When the app reports recorded requests, click **View my widgets**. Control-click the desktop, choose **Edit Widgets**, search for **AI Usage**, and add **AI usage totals** or **AI plan limits**. Control-click a placed widget to choose its period or plan.
3. Keep the menu bar app running for automatic updates. **Open at login** is optional under **Widgets → Preferences**. Reopening the app restores your read-only folder permissions. **Refresh now** reads the sources again.

| Source | What becomes available |
|---|---|
| Claude Code history (`.claude`) | Requests, tokens and estimated API value from recorded assistant usage |
| Codex history (`.codex`) | Recorded requests and tokens in current and archived sessions, plus limit windows when a session includes them |
| Antigravity history (`.gemini`) | Recorded usage in the IDE and CLI conversation databases. Only checkpointed metadata is read. |
| Sign in with ChatGPT | Account-wide limit readings directly from OpenAI, including on a Mac with no Codex history |
| Claude Code status line | The windows Claude reports after a reply, such as weekly or five-hour limits. Choose **Set up…**, copy the supplied setting, merge it into your Claude Code settings, and send a message. An existing status-line command can be preserved. AI Usage never edits Claude Code settings. |

History covers activity recorded on this Mac. A connected tool with empty history shows no recorded requests. Signing in for limits alone does not supply historic token totals. An API-equivalent estimate uses the bundled price table and excludes requests whose model has no listed price.

## Google usage with Antigravity

1. On the Mac where you use the Antigravity app or its CLI, open **AI Usage → Sources → This Mac**. Click **Google setup…** beside **Google Antigravity**. **Local usage** explains the folder and widget choices and can open the picker for you.
2. Select the **.gemini** folder in your home folder and click **Connect**. The picker shows hidden folders. You can also press **Shift–Command–G** and enter `~/.gemini`. If there is no history yet, complete a request in Antigravity, let it save the conversation, then click **Refresh now** in AI Usage.
3. Add **AI usage totals** to see requests, tokens, and estimated API value across the sources you connected. For Antigravity’s own seven-day totals, add a medium or larger **AI plan limits** widget, edit it, and choose **Google AI (Antigravity)**. Local widgets group the models used in Antigravity together.

**Remaining quota.** In **Google setup… → Remaining quota**, sign in to the Antigravity desktop app and leave it running. If you already have an AI Usage dashboard running on this Mac, click **Connect to localhost:8796**. Otherwise the guide has a **Copy Terminal command** button. With Python 3.9 or newer, paste that command into Terminal and press Return. It downloads and verifies a pinned dashboard source archive, serves Google's quota readings only on your Mac, and exits when you press Control-C. Run the command again when you want to restart it. The first check can take a few minutes. In **AI plan limits**, choose **Google AI (Antigravity)** for the available percentages and reset times. Return to **Sources → This Mac** for your saved history.

You can also open this guide from **Sources → Dashboard → Google quota setup…**. With a [full dashboard](../README.md#install), the same dashboard can supply both history and live limits, with individual models in its **By model and effort** table.

## Other sources

**Demo** uses fictional data and works offline. **Dashboard** reads an AI Usage server at an address you supply, including a path such as `my-server.local:8088/ai-usage/`. This mode also supports live Antigravity limits and server-side background job attribution. Existing installations with a saved dashboard keep that selection when upgraded.

The app refreshes on a five-minute timer. Widgets read shared summaries in the app group. In local mode only the app holds folder permissions and runs provider connections. When the app has been closed long enough for a reading to age, open it from the widget to refresh. In dashboard mode a widget can also refresh directly from the server. macOS schedules timeline redraws.

## Build

Use Xcode and XcodeGen. Put your development team and bundle prefix in the untracked `macos/Local.xcconfig`:

```
DEVELOPMENT_TEAM = ABCDE12345
AI_USAGE_BUNDLE_PREFIX = com.example.you
```

From the repository root, run `macos/scripts/build.sh` and `macos/scripts/install.sh` for a local Apple Development build. The build downloads a pinned, checksum-verified, Apple-silicon Codex helper from OpenAI and checks its original signature before signing it for the app sandbox. The helper ships inside the app. Its notices are in the app resources.

For an isolated first-run test, build with `macos/scripts/build.sh --fresh-install`, then copy **AI Usage Fresh Install.app** from `macos/build.noindex/FreshInstall` to Applications and open it. It has its own folder permissions, preferences, widget data and links. Select **AI Usage Fresh Install** in the widget gallery. The first-run window appears the first time you launch that identity.

Run `macos/release/archive.sh` to archive, export and verify a local Mac App Store installer package. It uses Xcode’s configured developer account. See the [release files](release/README.md) and [privacy policy](../docs/privacy.md).

## Verify

Run `swift test --package-path macos` and `python3 -m unittest discover -s tests -t .`. The Swift tests include clean-source selection, legacy dashboard migration, local reading and cache isolation, token deduplication, partial log writes, read-only Antigravity accounting, and limits without history.

The app supports `--refresh-once`, `--set-server ADDRESS`, and `--render-previews FOLDER --sample`. For rendering, choose a folder inside the signed app’s own sandbox container. `--render-store-assets FOLDER` renders the listing artwork from fictional data and a clean setup view. Neither rendering command installs widgets. Use a placed widget to check delivery and freshness.
