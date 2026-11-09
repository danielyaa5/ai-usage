# Mac App Store release files

- [Listing and review notes](listing.json)
- Upload [plan limits](screenshots/03-plan-limits.png), [usage totals](screenshots/01-desktop-usage.png), then [local setup](screenshots/02-connect-history.png). All three are opaque 1440 × 900 PNGs with fictional data.
- The [privacy policy](../../docs/privacy.md) is bundled in the app. Publish the [support page](https://danielyakobian.com/ai-usage/) and [online policy](https://danielyakobian.com/ai-usage/privacy/) before submitting.
- Run `python3 macos/release/preview.py /path/to/listing.html` from the repository root to build a portable listing preview. Pass `--site-preview /path/to/staged/ai-usage` to include the support and privacy pages for offline review. The U.S. price and screenshot order come from the listing file.

## Local archive and export

Set the team and bundle prefix in the ignored local Xcode configuration. Run `macos/release/archive.sh`. The archive is at `macos/build.noindex/Store/AIUsage.xcarchive` and the local Store package at `macos/build.noindex/Store/export/AI Usage.pkg`. The verifier opens the exported installer, checks the distribution signature of each executable, the embedded helper’s sandbox inheritance, the app group, the network settings and bundled resources. It does not upload or submit a build.

For review, start in Demo and add a desktop widget. To verify the local flow, select a tool’s folder from a clean installation, compare the widget with the selected history, append a request, and relaunch. The picker should not reopen and the widget should advance. Keep any private test results and signing details out of this repository.
