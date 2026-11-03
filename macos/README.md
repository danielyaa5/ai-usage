# AI Usage widgets for macOS

Desktop and Notification Center widgets for the AI Usage dashboard, with a small menu bar app that
keeps them current.

- **AI plan limits** (small, medium, large, extra large): what's left of each plan's 5-hour and
  weekly limits, when each resets, and any reader problem the dashboard reports (in full where it
  fits, such as "The Antigravity app is not running on this Mac", or as "Antigravity: app not
  running"). From the medium size up, the plans line up in a table with a column per limit. Edit the
  widget to show one plan in more detail.
- **AI usage totals** (small, medium): API-equivalent value, model requests, tokens processed and
  background jobs, for today, the last 7 days or the last 30 days.

Limits read 6 or more hours ago, and windows whose reset time has passed, are drawn in gray with a
faded bar, and the widget says how old they are ("as of 7 h ago", "reset due") where it has room.
When the dashboard can't be reached the widgets keep the last reading and say how old it is
("Offline · from 14:05", or "Refresh needed" after 45 minutes); click that line to read again.
Clicking a widget opens the dashboard.

## How it works

The dashboard serves a small JSON reply for the widgets at `/api/widget?range=today|7d|30d` (see the
main README). The menu bar app reads it every 5 minutes, backing off to 30 minutes while it fails,
and keeps the reply in an App Group container it shares with the widget extension. It asks macOS to
redraw the widgets when something they show changes. Each widget timeline uses the shared reply when
it is under 6 minutes old and otherwise reads the dashboard itself, so the widgets still work when the
app isn't running. When the app's read fails it notes that in the container as well, so the widgets
say "Offline" as soon as the app can't reach the dashboard either, and clicking that line makes them
read the dashboard themselves. Nothing else is stored, and no credentials are involved.

The app opens at login (turn that off in its settings) and can hide its menu bar icon.

## Build and install

You need macOS 14 or later, Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`) and an Apple Development certificate (a free Apple account's personal team
works). The app and its widgets must be signed by the same team to share their App Group.

1. Create `macos/Local.xcconfig` (git ignores it) with your team ID and a bundle ID prefix of your own:

   ```
   DEVELOPMENT_TEAM = ABCDE12345
   AI_USAGE_BUNDLE_PREFIX = com.example.you
   ```

2. Build, sign and install:

   ```sh
   macos/scripts/build.sh      # -> macos/build.noindex/AI Usage.app
   macos/scripts/install.sh    # -> /Applications/AI Usage.app, started in the background
   ```

   `build.sh` builds with Xcode unsigned, then signs the extension and the app with your certificate.
   Run it in a Terminal on the Mac: over SSH, `codesign` usually can't use the login keychain.

3. Click the chart icon in the menu bar, choose **Settings…**, and enter the dashboard's address as
   you open it in a browser: `localhost:8796` on the Mac that runs AI Usage, or that Mac's name or
   address from another one (`my-mac.local:8796`). A path works too, such as
   `my-server.local:8088/ai-usage/`. The first time the app reads another Mac, macOS asks to let it
   find devices on your local network; allow it, or the widgets stay empty. The widgets share the
   app's permission. A Tailscale address (`100.x.y.z` or `name.tailnet.ts.net`) needs no such
   permission.

4. Control-click the desktop, choose **Edit Widgets**, and search for AI Usage.

You can also open `AIUsage.xcodeproj` (after `xcodegen generate` in `macos/`) and build in Xcode
with automatic signing.

## Command line

The app's executable takes a few options for scripting and testing; with any of them it shows no
menu bar icon and quits when done:

```sh
APP="/Applications/AI Usage.app/Contents/MacOS/AI Usage"
"$APP" --set-server my-mac.local:8796                 # save the dashboard address
"$APP" --refresh-once                                 # read every period now and redraw the widgets
"$APP" --render-previews ~/Desktop/widgets --sample   # every layout, light and dark, as PNG files
```

`--render-previews` draws the same views the widgets use, at the system widget sizes, from the
dashboard or (with `--sample`) from made-up numbers, which is what screenshots should use. It also
draws the states that need the most room: `-offline`, and with `--sample`, `-problems` (reader errors
and old readings), `-problems-offline` and `-old`.

## Test

```sh
cd macos && swift test
```

The tests cover the reply format, the shared cache (a newer reading is never replaced by an older
one, a cached reading keeps its original time, and the app's failures and refresh requests stop the
widgets reusing it), addresses, formatting, reader errors in a few words and the age of old readings.
They don't show that a placed widget draws; check that on the desktop after installing.

## Troubleshooting

- **AI Usage isn't in the widget gallery.** Open the app once from /Applications. Keep a single copy
  of the app: remove other builds (`mdfind "kMDItemCFBundleIdentifier == '*AIUsage'"` lists them).
  Then `killall chronod NotificationCenter` and look again.
- **"Can't reach AI Usage".** Check the address in a browser. If the browser works but the widgets
  don't, see System Settings › Privacy & Security › Local Network and make sure AI Usage is on (an
  update can turn it off; switching it off and on again restores it).
- **Old numbers.** The widgets redraw within a few minutes of the app reading something new, but
  macOS decides exactly when. The menu bar panel always shows the latest reading.
- **Logs.** `log stream --predicate 'process == "AIUsageWidgets" OR process == "AI Usage"'`.
