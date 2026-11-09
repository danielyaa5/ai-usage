# AI Usage privacy policy

AI Usage for Mac reads usage information from the sources you connect. The developer operates no usage collection service. The app includes no advertising, tracking or developer analytics.

## This Mac

When you select a Claude Code, Codex or Antigravity folder, macOS grants read-only access. AI Usage reads usage records to count requests and tokens and, where available, estimate their value at published API rates. It saves a folder permission in the app’s private storage. The app and its desktop widgets share summaries on your Mac. Summaries contain counts, estimates, limit windows, and observation times. They do not contain prompts, responses, file contents or account identifiers.

Choose **Disconnect history** in the tool’s connection to revoke the app’s saved access and remove its contribution to the summaries. The original tool’s files stay on your Mac.

## Optional connections

- **ChatGPT sign-in.** Choosing this option opens OpenAI’s sign-in page. A bundled OpenAI helper contacts OpenAI to authenticate and request account limits. The helper keeps a separate sign-in inside AI Usage’s sandbox. AI Usage does not read your existing Codex credentials. Sign out in the ChatGPT connection to disconnect. OpenAI handles sign-in and limit requests under its own privacy policy.
- **Claude Desktop quota.** When you grant read-only access to the Claude application-support folder, AI Usage opens only the plan-usage history file. It reads the latest saved percentages and observation time. Account identifiers, conversations and credentials are excluded. If you enter percentages from Claude’s Usage page, the app records those values and the entry time locally. A newer desktop sample replaces the entry. **Disconnect Desktop** removes the saved permission and entry.
- **Claude Code in Terminal.** If you paste the optional setup request into the interactive Claude Code terminal, it can configure its status line to send AI Usage the limits it reports. The installed app shares only percentages and reset times with a protected listener on this Mac. The setup request contains no connection token. Choose **Disconnect** under Claude Code’s remaining quota to stop receiving readings. You can ask Claude Code to remove the status-line change.
- **Google Antigravity quota.** If you connect quota, AI Usage reads Antigravity’s local service registration under the folder permission you grant. It verifies the running Google-signed server and its local TLS certificate, and requests quota from that server on this Mac. The service’s per-process token is held in memory during the request. Only quota groups, remaining percentages, reset times and observation times are shared with the widget. Choose **Disconnect quota** in the Google Antigravity connection to stop these checks and remove its saved permission.
- **Dashboard.** Choosing Dashboard sends summary requests to the address you enter. The administrator of that dashboard controls its data and logs. No dashboard is needed for This Mac.
- **Demo.** Demo uses fictional data. It does not require an account or a network connection.

## Bug reports and feedback

When you choose **Send report**, Cloudflare and Resend deliver your summary, description, optional reply address and any screenshots you selected to the private AI Usage support inbox. You can review or turn off diagnostics before sending. Diagnostics include the app and macOS versions, widget settings, and which sources are connected. They exclude conversations, usage figures, account identifiers, tokens, server addresses and file paths. Screenshots are re-encoded without their original filenames or image metadata. Their visible contents are included.

For privacy and support questions, visit the [AI Usage support page](https://danielyakobian.com/ai-usage/).
