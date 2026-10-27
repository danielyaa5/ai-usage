# Project guidance

- Read-only toward the tools it measures: never write to `~/.claude`, `~/.codex` or `~/.gemini`
  data, never read credential stores, and never store prompt text.
- Standard library only; the LaunchAgent runs `/opt/homebrew/bin/python3`.
- The dashboard answers loopback, private-network and Tailscale clients with an allowed Host header;
  the OTLP receiver binds to loopback only. Do not expose either through a public tunnel.
- The Antigravity quota reader may use a language server's CSRF token only in memory and only against
  that process's own loopback port. Never log, store or print it, and drop personal fields from replies.
- Antigravity's protobuf field numbers are inferred from data. Recheck them with
  `ai_usage/protowire.py` after an Antigravity update if token counts drop to zero.
- Price changes go in `ai_usage/pricing.json` with the date and source. Job attribution rules go in
  `ai_usage/jobs.json`.
- Run `python3 -m unittest discover -s tests -t .` and check the page at desktop and phone widths in
  light and dark mode before finishing a change.
- Keep commits authored by the repository owner without tool attribution.
