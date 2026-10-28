"""Attribute usage to the job or app that caused it, using jobs.local.json or else jobs.json."""
import json
import os
import re
from pathlib import Path

# jobs.json holds example rules. Your own rules go in jobs.local.json, which git ignores; when it
# exists it is used instead.
JOBS_PATH = Path(__file__).with_name('jobs.json')
LOCAL_JOBS_PATH = Path(__file__).with_name('jobs.local.json')
_cache = {'key': None, 'data': None}


def jobs_path():
    return LOCAL_JOBS_PATH if LOCAL_JOBS_PATH.exists() else JOBS_PATH


def rules():
    path = jobs_path()
    key = (str(path), os.path.getmtime(path))
    if _cache['key'] != key:
        data = json.loads(path.read_text())
        for rule in data.get('prompt_rules', []):
            if 'regex' in rule:
                rule['_re'] = re.compile(rule['regex'], re.S)
        for rule in data.get('cwd_rules', []):
            rule['_prefix'] = os.path.realpath(os.path.expanduser(rule['prefix']))
        _cache.update(key=key, data=data)
    return _cache['data']


def title(text):
    words = re.split(r'[\s_-]+', str(text).strip())
    return ' '.join(w if any(c.isupper() for c in w) else w.capitalize() for w in words if w)


def scheduled(task_id):
    names = rules().get('scheduled_names', {})
    return 'Scheduled: ' + names.get(task_id, title(task_id))


def from_prompt(prompt):
    """(job, detail) for a first prompt, or None."""
    prompt = (prompt or '').strip()
    if not prompt:
        return None
    for rule in rules().get('prompt_rules', []):
        if 'contains' in rule and rule['contains'] not in prompt:
            continue
        if 'startswith' in rule and not prompt.startswith(rule['startswith']):
            continue
        groups = {}
        if '_re' in rule:
            match = rule['_re'].search(prompt)
            if not match:
                continue
            groups = {k: title(v) for k, v in match.groupdict().items() if v}
        return rule['job'].format(**groups), rule.get('detail')
    return None


def from_cwd(cwd):
    if not cwd:
        return None
    real = os.path.realpath(os.path.expanduser(cwd))
    for rule in rules().get('cwd_rules', []):
        if real == rule['_prefix'] or real.startswith(rule['_prefix'] + os.sep):
            return rule['job'], rule.get('detail')
    return None


def from_telemetry(resource):
    """Job name from an OTLP resource's attributes, or None."""
    value = resource.get(rules().get('telemetry_attribute', 'ai_usage.job'))
    if not value:
        return None
    return rules().get('telemetry_jobs', {}).get(value, value)


def folder(cwd):
    """A short project label for a working folder: '~/Developer/ai-usage' -> 'ai-usage'."""
    if not cwd:
        return None
    home = str(Path.home())
    path = os.path.realpath(cwd)
    if path in (home, os.path.realpath(home)):
        return '~'
    developer = os.path.join(home, 'Developer')
    if path.startswith(developer + os.sep):
        return path[len(developer) + 1:].split(os.sep)[0]
    if path.startswith(('/tmp', '/private/tmp', '/private/var', '/var/folders')):
        return 'temp folder'
    return os.path.basename(path)
