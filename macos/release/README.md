# Mac App Store release files

- [Listing and review notes](listing.json)
- [Store screenshots](screenshots/01-desktop-usage.png), [local setup](screenshots/02-connect-history.png), and [plan limits](screenshots/03-plan-limits.png). All three PNGs are 1440 × 900 and contain fictional data.
- [Privacy policy](../../docs/privacy.md). Its listing URL becomes usable once the policy is published to the public repository’s default branch.
- [Support](https://github.com/danielyaa5/ai-usage/issues)

## Local archive and export

Set the team and bundle prefix in the ignored local Xcode configuration. Run `macos/release/archive.sh`. The archive is at `macos/build.noindex/Store/AIUsage.xcarchive` and the local Store package at `macos/build.noindex/Store/export/AI Usage.pkg`. The verifier opens the exported installer, checks the distribution signature of each executable, the embedded helper’s sandbox inheritance, the app group, the network settings and bundled resources. It does not upload or submit a build.

For review, start in Demo and add a desktop widget. To verify the local flow, select a tool’s folder from a clean installation, compare the widget with the selected history, append a request, and relaunch. The picker should not reopen and the widget should advance. Keep any private test results and signing details out of this repository.
