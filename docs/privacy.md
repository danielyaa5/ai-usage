# AI Usage privacy policy

AI Usage for Mac reads usage information from the sources you connect. The developer operates no usage collection service. The app includes no advertising, tracking or developer analytics.

## This Mac

When you select a Claude Code, Codex or Antigravity folder, macOS grants read-only access. AI Usage reads usage records to count requests and tokens and, where available, estimate their value at published API rates. It saves a folder permission in the app’s private storage. The app and its desktop widgets share summaries on your Mac. Summaries contain counts, estimates, limit windows, and observation times. They do not contain prompts, responses, file contents or account identifiers.

Disconnect a folder in Sources to revoke the app’s saved access and remove its contribution to the summaries. The original tool’s files stay on your Mac.

## Optional connections

- **ChatGPT sign-in.** Choosing this option opens OpenAI’s sign-in page. A bundled OpenAI helper contacts OpenAI to authenticate and request account limits. The helper keeps a separate sign-in inside AI Usage’s sandbox. AI Usage does not read your existing Codex credentials. Sign out in Sources to disconnect. OpenAI handles sign-in and limit requests under its own privacy policy.
- **Claude Code status line.** If you add the supplied setting, Claude Code sends its reported limit windows to a token-protected listener on this Mac. AI Usage accepts these readings only over loopback. You can turn the receiver off in Sources and remove the setting from Claude Code.
- **Google Antigravity quota.** If you connect quota, AI Usage reads Antigravity’s local service registration under the folder permission you grant. It verifies the running Google-signed server and its local TLS certificate, and requests quota from that server on this Mac. The service’s per-process token is held in memory during the request. Only quota groups, remaining percentages, reset times and observation times are shared with the widget. Disconnect quota in Account limits to stop these checks and remove its saved permission.
- **Dashboard.** Choosing Dashboard sends summary requests to the address you enter. The administrator of that dashboard controls its data and logs. No dashboard is needed for This Mac.
- **Demo.** Demo uses fictional data. It does not require an account or a network connection.

For privacy and support questions, visit the [AI Usage support page](https://github.com/danielyaa5/ai-usage/issues).
