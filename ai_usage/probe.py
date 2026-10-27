"""Read the Claude plan's 5-hour and weekly utilization.

`claude -p --output-format stream-json` emits a `rate_limit_event` with the account's unified
windows. A one-word Haiku request with tools, MCP and session files off costs about $0.0005 at API
prices, a negligible share of a Max plan. No credentials are read here; the CLI uses its own sign-in.
"""
import json
import os
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

from .store import get_kv, put_limit, set_kv

MODEL = 'claude-haiku-5-5'
TIMEOUT = 90
STRIP = ('ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_BASE_URL', 'CLAUDE_CODE_USE_BEDROCK',
         'CLAUDE_CODE_USE_VERTEX', 'CLAUDE_CODE_USE_FOUNDRY', 'CLAUDECODE')


def claude_binary():
    found = shutil.which('claude')
    candidate = Path.home() / '.local/bin/claude'
    return found or (str(candidate) if candidate.exists() else None)


def parse(stdout):
    """Return the rate_limit_info dict from stream-json output, or None."""
    for line in stdout.splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if isinstance(event, dict) and event.get('type') == 'rate_limit_event':
            return event.get('rate_limit_info') or {}
    return None


def record(db, info, observed_at=None):
    windows = info.get('unifiedWindows') or {}
    if not windows and info.get('rateLimitType'):
        windows = {info['rateLimitType']: {'utilization': info.get('utilization'), 'resetsAt': info.get('resetsAt')}}
    extra = {k: info.get(k) for k in ('status', 'overageStatus', 'overageDisabledReason', 'isUsingOverage')}
    for name, window in windows.items():
        utilization = window.get('utilization')
        if utilization is None:
            continue
        put_limit(db, 'anthropic', name, round(float(utilization) * 100, 1), window.get('resetsAt'),
                  'Claude Max 20x', extra, observed_at)
    return len(windows)


def run(db, otel_env=None):
    binary = claude_binary()
    if not binary:
        set_kv(db, 'probe_error', 'Claude CLI not found')
        return None
    env = {k: v for k, v in os.environ.items() if k not in STRIP}
    env.update(otel_env or {})
    cmd = [binary, '-p', '--safe-mode', '--output-format', 'stream-json', '--verbose', '--model', MODEL,
           '--effort', 'low', '--tools', '', '--strict-mcp-config', '--mcp-config', '{"mcpServers":{}}',
           '--no-session-persistence', '--disable-slash-commands', 'Reply with just OK']
    with tempfile.TemporaryDirectory(prefix='ai-usage-probe-') as cwd:
        try:
            proc = subprocess.run(cmd, cwd=cwd, env=env, stdin=subprocess.DEVNULL, capture_output=True,
                                  text=True, timeout=TIMEOUT)
        except (subprocess.TimeoutExpired, OSError) as error:
            set_kv(db, 'probe_error', f'probe failed: {error}')
            return None
    info = parse(proc.stdout)
    set_kv(db, 'probe_last', int(time.time()))
    if info is None:
        set_kv(db, 'probe_error', f'no rate_limit_event (exit {proc.returncode}): {proc.stderr[-300:]}')
        return None
    set_kv(db, 'probe_error', None)
    record(db, info)
    return info


def due(db, interval):
    return time.time() - (get_kv(db, 'probe_last', 0) or 0) >= interval
