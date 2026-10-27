# AI Usage

A local dashboard for the Claude, ChatGPT (Codex) and Gemini (Antigravity) usage of the jobs and
apps on this Mac, with the plan limits that matter for flat-rate subscriptions.

Open `http://my-mac.local:8796` from the home network or Tailscale.

## What it shows

- **Plan limits**: Claude's 5-hour and weekly utilization, ChatGPT Pro's weekly Codex limit, and
  extra-usage status. Limits are account-wide; usage figures are for this Mac only.
- **API-equivalent value**: what the same requests would cost on pay-per-token API keys, by plan,
  job, model and day. The subscriptions are flat-rate, so this is value used, not money spent.
- **Jobs and apps**: scheduled tasks, background jobs (ai-trader, price-watch, the M2 server page)
  and interactive sessions, each with its models, tokens and last request.

## Data sources

| Source | Read from | Notes |
|---|---|---|
| Claude Code | `~/.claude/projects/**/*.jsonl` | Desktop session titles and scheduled-task ids from the Claude app's session records |
| Codex | `~/.codex/sessions` and `archived_sessions` rollouts | Per-response usage records; `rate_limits` give the ChatGPT plan's limit |
| Antigravity | `~/.gemini/antigravity{,-cli}/conversations/*.db` | Protobuf blobs decoded by `ai_usage/protowire.py` |
| No-log calls | OTLP/HTTP JSON on `127.0.0.1:4318` | `claude -p --no-session-persistence` and `codex exec --ephemeral` save nothing on disk |
| Claude limits | `claude -p --output-format stream-json` | A one-word Haiku request every 20 minutes returns a `rate_limit_event` |
| ChatGPT limits | `codex app-server` | `account/rateLimits/read` every 10 minutes; no model usage. Session logs only hold limits as of the last Codex request on this Mac |
| Antigravity limits | the running Antigravity app's `language_server` | `RetrieveUserQuotaSummary` on its loopback port every 5 minutes: 5-hour and weekly buckets for the Gemini group and the Claude/GPT-OSS group; `GetUserStatus` names the tier. No model usage |

Nothing reads credentials or sign-in tokens. The Antigravity reader takes the language server's
per-process CSRF token from the process list and sends it only back to that process's loopback port;
it is never stored or logged, and the name and email in its replies are discarded. Logs are read
incrementally once a minute and never modified. Prompts are not stored; Claude Code and Codex
redact them from telemetry by default. Antigravity limits refresh only while the Antigravity app (or
an `agy` run) is open on this Mac.

Jobs are attributed by telemetry resource attribute, first prompt, or working folder, using
`ai_usage/jobs.json`. Editing it makes the next scan read every log again, so stored events take the
new rules. API prices and plan prices live in `ai_usage/pricing.json`; both reload on change.

## Install

Requires macOS and `/opt/homebrew/bin/python3` (3.9 or later). No packages are needed.

```sh
python3 install.py                 # dashboard LaunchAgent com.danielyakobian.ai-usage
python3 install.py --skip-dashboard --wire-jobs --codex
```

`--wire-jobs` adds `CLAUDE_CODE_ENABLE_TELEMETRY` and `OTEL_*` settings, including
`OTEL_RESOURCE_ATTRIBUTES=ai_usage.job=<name>`, to the LaunchAgents listed in `install.py`. It
reloads a job only when that job is not running; add `--restart-running` to restart continuous jobs.
`--codex` appends an `[otel]` exporter to `~/.codex/config.toml`. Codex telemetry for sessions that
also write a rollout is discarded in favor of the rollout. `--unwire` reverses both. Every edited
file is first copied to `~/Library/Application Support/ai-usage/backups/`.

Reinstalling a wired job's own LaunchAgent (for example the M2 server page's `scripts/install.py`)
drops the telemetry settings; run `--wire-jobs` again afterwards.

## Operate

```sh
launchctl kickstart -k gui/$(id -u)/com.danielyakobian.ai-usage
tail -f ~/Library/Logs/ai-usage.log
python3 -m unittest discover -s tests -t .
```

Data: `~/Library/Application Support/ai-usage/usage.sqlite`. Deleting it triggers a full rescan of
the logs still on disk; telemetry-only history and limit history would be lost.
