"""ChatGPT plan limits straight from Codex.

Session logs only carry rate limits as of the last Codex request made on this Mac, which goes stale
when Codex is used elsewhere. `codex app-server` (JSON-RPC over stdio) answers
`account/rateLimits/read` from the account's current state without running a model, so this is
polled on a timer instead. Codex uses its own sign-in; nothing here reads credentials.
"""
import json
import select
import shutil
import subprocess
import time
from pathlib import Path

from .store import get_kv, put_limit, set_kv

TIMEOUT = 45


def codex_binary():
    found = shutil.which('codex')
    candidate = Path.home() / '.local/bin/codex'
    return found or (str(candidate) if candidate.exists() else None)


def request(binary, method):
    """Start an app-server, initialize it, call one method and return its result."""
    proc = subprocess.Popen([binary, 'app-server'], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, text=True)
    try:
        def send(message):
            proc.stdin.write(json.dumps(message) + '\n')
            proc.stdin.flush()

        def wait_for(message_id):
            deadline = time.time() + TIMEOUT
            while time.time() < deadline:
                ready, _, _ = select.select([proc.stdout], [], [], 1)
                if not ready:
                    continue
                line = proc.stdout.readline()
                if not line:
                    break
                try:
                    message = json.loads(line)
                except ValueError:
                    continue
                if message.get('id') == message_id:
                    if 'error' in message:
                        raise RuntimeError(str(message['error'])[:300])
                    return message.get('result') or {}
            raise TimeoutError(f'no reply to request {message_id}')

        send({'id': 1, 'method': 'initialize',
              'params': {'clientInfo': {'name': 'ai-usage', 'title': 'AI usage dashboard', 'version': '1'}}})
        wait_for(1)
        send({'method': 'initialized'})
        send({'id': 2, 'method': method})
        return wait_for(2)
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()


def record(db, result, observed_at=None):
    """Store each window of an account/rateLimits/read result. Returns the count."""
    limits = result.get('rateLimitsByLimitId') or {}
    if not limits and result.get('rateLimits'):
        limits = {result['rateLimits'].get('limitId') or 'codex': result['rateLimits']}
    count = 0
    for limit_id, limit in limits.items():
        prefix = 'codex' if limit_id == 'codex' else f'codex-{limit_id}'
        for name in ('primary', 'secondary'):
            window = limit.get(name)
            if not isinstance(window, dict) or window.get('usedPercent') is None:
                continue
            put_limit(db, 'openai', f'{prefix}_{name}', float(window['usedPercent']), window.get('resetsAt'),
                      limit.get('planType'), {'window_minutes': window.get('windowDurationMins'),
                                              'credits': limit.get('credits'), 'reached': limit.get('rateLimitReachedType'),
                                              'limit_name': limit.get('limitName')}, observed_at)
            count += 1
    return count


def poll(db):
    set_kv(db, 'codex_limits_last_try', int(time.time()))
    binary = codex_binary()
    if not binary:
        set_kv(db, 'codex_limits_error', 'Codex CLI not found')
        return 0
    try:
        count = record(db, request(binary, 'account/rateLimits/read'))
    except (OSError, RuntimeError, TimeoutError, ValueError) as error:
        set_kv(db, 'codex_limits_error', f'Codex limit read failed: {error}')
        return 0
    set_kv(db, 'codex_limits_error', None if count else 'Codex returned no rate limits')
    return count


def due(db, interval):
    return time.time() - (get_kv(db, 'codex_limits_last_try', 0) or 0) >= interval
