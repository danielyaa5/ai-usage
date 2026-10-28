"""Antigravity plan limits from the running Antigravity app's local language server.

The Antigravity app (and each `agy` run) starts a `language_server` that serves a Connect API on a
loopback port, guarded by a per-process CSRF token passed on its command line. Its
`RetrieveUserQuotaSummary` method returns the same quota groups the app shows: for each model
group (Gemini; Claude and GPT-OSS) a 5-hour and a weekly bucket with the fraction remaining and
the reset time. `GetUserStatus` names the subscription tier.

The token is read from the process list at poll time, held only in memory and sent only to that
process's own loopback port. No Google credentials are read, and nothing personal from the
responses (name, email) is stored. Polling costs no model usage.
"""
import json
import re
import ssl
import subprocess
import time
import urllib.error
import urllib.request
from datetime import datetime

from .store import get_kv, put_limit, set_kv

SERVICE = 'exa.language_server_pb.LanguageServerService'
TOKEN = re.compile(r'--csrf_token[= ](\S+)')
TIMEOUT = 15
INSECURE = ssl.create_default_context()
INSECURE.check_hostname = False
INSECURE.verify_mode = ssl.CERT_NONE  # the language server uses a self-signed loopback certificate


def servers(ps_output=None):
    """[(pid, csrf token)] for running Antigravity language servers, the app's own first."""
    if ps_output is None:
        ps_output = subprocess.run(['ps', '-axww', '-o', 'pid=,command='], capture_output=True, text=True,
                                   timeout=10).stdout
    found = []
    for line in ps_output.splitlines():
        pid, _, command = line.strip().partition(' ')
        if 'language_server' not in command or not pid.isdigit():
            continue
        if 'Antigravity.app' not in command and '.gemini/antigravity' not in command:
            continue
        match = TOKEN.search(command)
        if match:
            found.append((int(pid), match.group(1), 'Antigravity.app' in command))
    found.sort(key=lambda s: not s[2])
    return [(pid, token) for pid, token, _ in found]


def loopback_ports(pid):
    out = subprocess.run(['lsof', '-nP', '-a', '-p', str(pid), '-iTCP', '-sTCP:LISTEN', '-Fn'],
                         capture_output=True, text=True, timeout=10).stdout
    ports = []
    for line in out.splitlines():
        match = re.fullmatch(r'n(?:127\.0\.0\.1|\[::1\]|localhost):(\d+)', line.strip())
        if match:
            ports.append(int(match.group(1)))
    return ports


def call(port, token, method, body=None):
    data = json.dumps(body or {}).encode()
    headers = {'Content-Type': 'application/json', 'Connect-Protocol-Version': '1', 'X-Codeium-Csrf-Token': token}
    last_error = None
    for scheme in ('https', 'http'):
        request = urllib.request.Request(f'{scheme}://127.0.0.1:{port}/{SERVICE}/{method}', data=data,
                                         headers=headers, method='POST')
        try:
            with urllib.request.urlopen(request, timeout=TIMEOUT,
                                        context=INSECURE if scheme == 'https' else None) as response:
                return json.loads(response.read())
        except (urllib.error.URLError, ssl.SSLError, ConnectionError, TimeoutError, ValueError) as error:
            last_error = error
    raise ConnectionError(f'{method} on port {port}: {last_error}')


def iso_ts(value):
    try:
        return int(datetime.fromisoformat(str(value).replace('Z', '+00:00')).timestamp())
    except (TypeError, ValueError):
        return None


def record(db, summary, tier=None, observed_at=None):
    """Store each bucket of a RetrieveUserQuotaSummary response as a plan limit. Returns the count."""
    groups = (summary.get('response') or summary).get('groups') or []
    count = 0
    for order, group in enumerate(groups):
        for bucket in group.get('buckets') or []:
            remaining = bucket.get('remainingFraction')
            if remaining is None or not bucket.get('bucketId'):
                continue
            put_limit(db, 'google', bucket['bucketId'], round((1 - float(remaining)) * 100, 1),
                      iso_ts(bucket.get('resetTime')), tier,
                      {'group': group.get('displayName'), 'models': group.get('description'),
                       'window': bucket.get('window'), 'order': order}, observed_at)
            count += 1
    return count


def poll(db):
    try:
        candidates = servers()
    except (OSError, subprocess.SubprocessError) as error:
        set_kv(db, 'antigravity_quota_error', f'process list failed: {error}')
        return 0
    set_kv(db, 'antigravity_quota_last_try', int(time.time()))
    if not candidates:
        set_kv(db, 'antigravity_quota_error', 'The Antigravity app is not running on this Mac, so limits are not refreshing.')
        return 0
    errors = []
    for pid, token in candidates:
        for port in loopback_ports(pid):
            try:
                summary = call(port, token, 'RetrieveUserQuotaSummary')
            except ConnectionError as error:
                errors.append(str(error))
                continue
            try:
                status = call(port, token, 'GetUserStatus', {'metadata': {'ideName': 'antigravity', 'locale': 'en'}})
                user = status.get('userStatus') or {}
                tier = (user.get('userTier') or {}).get('description')
                if tier:
                    set_kv(db, 'antigravity_tier', tier)
                configs = (user.get('cascadeModelConfigData') or {}).get('clientModelConfigs') or []
                model_labels = {c['modelOrAlias']['model']: c['label'] for c in configs
                                if c.get('label') and (c.get('modelOrAlias') or {}).get('model')}
                if model_labels:
                    set_kv(db, 'antigravity_model_labels', {**(get_kv(db, 'antigravity_model_labels', {}) or {}), **model_labels})
            except ConnectionError:
                tier = get_kv(db, 'antigravity_tier')
            count = record(db, summary, tier or get_kv(db, 'antigravity_tier'))
            if count:
                set_kv(db, 'antigravity_quota_error', None)
                set_kv(db, 'antigravity_quota_last', int(time.time()))
                return count
    set_kv(db, 'antigravity_quota_error', 'Antigravity is running but did not return quota: ' + '; '.join(errors)[-300:])
    return 0


def due(db, interval):
    return time.time() - (get_kv(db, 'antigravity_quota_last_try', 0) or 0) >= interval
