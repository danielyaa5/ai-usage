#!/usr/bin/env python3
"""Run the dashboard on fictional data, for screenshots and UI work.

    python3 scripts/demo.py              # http://127.0.0.1:8797, Ctrl-C to stop
    python3 scripts/demo.py --port 9000

The data lives in a temporary folder that also stands in for the home folder, so no real logs are
read, no limit probes run and nothing is written outside that folder.
"""
import argparse
import os
import random
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from ai_usage import pricing, store  # noqa: E402

CLAUDE, OPENAI, GOOGLE = 'Claude Max 20x', 'ChatGPT Pro', 'Google (Antigravity)'
# job, tool, source, vendor, plan, [(model, effort, weight)], requests per day, details
JOBS = [
    ('Claude Code (interactive)', 'Claude Code', 'claude_transcript', 'anthropic', CLAUDE,
     [('claude-opus-5-5', 'xhigh', 3), ('claude-opus-5-5', 'high', 2), ('claude-sonnet-5-5', 'medium', 1)],
     90, ['recipe-app', 'home-lab', 'blog']),
    ('Codex (interactive)', 'Codex', 'codex_rollout', 'openai', OPENAI,
     [('gpt-6-astra', 'high', 2), ('gpt-6.1-sol', 'medium', 3)], 45, ['recipe-app', 'dotfiles']),
    ('Scheduled: Morning Brief', 'Claude Code', 'claude_transcript', 'anthropic', CLAUDE,
     [('claude-sonnet-5-5', 'high', 1)], 8, ['Morning Brief (8 AM daily)']),
    ('Nightly report', 'Codex', 'otel_codex', 'openai', OPENAI,
     [('gpt-6.1-sol', 'low', 1)], 6, ['log summary']),
    ('Price checker', 'Antigravity CLI', 'antigravity_cli', 'google', GOOGLE,
     [('gemini-3.8-flash', 'high', 1)], 12, ['deal research']),
    ('Antigravity (interactive)', 'Antigravity IDE', 'antigravity_ide', 'google', GOOGLE,
     [('gemini-4-argon', 'high', 2), ('claude-opus-5-5', 'high', 1)], 20, ['garden-planner']),
    ('Usage dashboard (limit probe)', 'Claude Code', 'otel_claude', 'anthropic', CLAUDE,
     [('claude-haiku-5-5', 'low', 1)], 72, [None]),
]


def seed(db, days=30, now=None):
    rng = random.Random(7)
    now = int(now or time.time())
    events = []
    for job, tool, source, vendor, plan, models, per_day, details in JOBS:
        for day in range(days):
            busy = 0.4 + 0.6 * rng.random() if job.endswith('(interactive)') else 1
            for n in range(int(per_day * busy)):
                model, effort, _ = rng.choices(models, weights=[m[2] for m in models])[0]
                small = 'haiku' in model or job.startswith('Usage')
                inp = rng.randint(2, 40) if small else rng.randint(200, 6000)
                cache_read = 0 if small else rng.randint(8_000, 160_000)
                cache_write = 0 if small else rng.randint(0, 12_000)
                output = rng.randint(1, 8) if small else rng.randint(150, 4_000)
                ts = now - day * 86400 - rng.randint(0, 86399)
                if ts > now:
                    continue
                events.append(dict(
                    id=f'demo:{job}:{day}:{n}', ts=ts, source=source, vendor=vendor, plan=plan, tool=tool, model=model,
                    job=job, detail=rng.choice(details), session=f'demo-{job}-{day}', cwd=None, input=inp,
                    cache_read=cache_read, cache_write=cache_write, output=output, reasoning=output // 3,
                    cost_usd=pricing.cost(model, inp, cache_read, cache_write, output), cost_basis='priced',
                    speed=None, effort=effort))
    store.put_events(db, events)
    hour, week = now + 2 * 3600 + 900, now + 3 * 86400 + 5 * 3600
    store.put_limit(db, 'anthropic', 'five_hour', 34.0, hour, CLAUDE, {'status': 'allowed', 'overageStatus': 'rejected'}, now)
    store.put_limit(db, 'anthropic', 'seven_day', 58.0, week, CLAUDE, {'status': 'allowed', 'overageStatus': 'rejected'}, now)
    store.put_limit(db, 'openai', 'codex_primary', 12.0, now + 3 * 3600, 'pro', {'window_minutes': 300}, now)
    store.put_limit(db, 'openai', 'codex_secondary', 41.0, now + 4 * 86400, 'pro', {'window_minutes': 10080}, now)
    for order, (group, used) in enumerate((('Gemini', (22.0, 47.0)), ('Claude and GPT-OSS', (8.0, 15.0)))):
        for window, pct in zip(('5h', 'weekly'), used):
            store.put_limit(db, 'google', f'{group}-{window}', pct, now + (4 * 3600 if window == '5h' else 5 * 86400),
                            'Google AI Ultra', {'group': group, 'window': window, 'order': order}, now)
    for key, value in (('antigravity_tier', 'Google AI Ultra'), ('probe_last', now), ('antigravity_quota_last', now),
                       ('telemetry_last', now - 300), ('telemetry_count', 4210)):
        store.set_kv(db, key, value)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--port', type=int, default=8797)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='ai-usage-demo-') as home:
        db_path = Path(home) / 'usage.sqlite'
        db = store.connect(db_path)
        seed(db)
        db.close()
        env = dict(os.environ, HOME=home, AI_USAGE_DATA=home, AI_USAGE_NAME='my-mac')
        cmd = [sys.executable, '-m', 'ai_usage.server', '--host', '127.0.0.1', '--port', str(args.port),
               '--otlp-port', str(args.port + 1), '--db', str(db_path), '--probe-interval', '0',
               '--quota-interval', '0', '--codex-interval', '0']
        print(f'Demo dashboard on http://127.0.0.1:{args.port} (fictional data). Ctrl-C to stop.')
        try:
            subprocess.run(cmd, cwd=ROOT, env=env, check=False)
        except KeyboardInterrupt:
            pass


if __name__ == '__main__':
    main()
