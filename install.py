#!/usr/bin/env python3
"""Install the AI usage dashboard as a LaunchAgent and connect the jobs whose model calls leave no logs.

    python3 install.py                 # install or restart the dashboard (port 8796, OTLP on 127.0.0.1:4318)
    python3 install.py --wire-jobs     # add telemetry settings to the job LaunchAgents listed in local.json
    python3 install.py --codex         # add an [otel] exporter to ~/.codex/config.toml
    python3 install.py --unwire        # undo --wire-jobs and --codex

--wire-jobs reloads a job only when it is not running. Jobs that run continuously (KeepAlive) are
restarted only with --restart-running. Every edited file is backed up first.
"""
import argparse
import os
import plistlib
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

from ai_usage import local

ROOT = Path(__file__).resolve().parent
LABEL = 'com.danielyakobian.ai-usage'
AGENTS = Path.home() / 'Library/LaunchAgents'
PLIST = AGENTS / f'{LABEL}.plist'
LOG = Path.home() / 'Library/Logs/ai-usage.log'
BACKUPS = Path.home() / 'Library/Application Support/ai-usage/backups'
PYTHON = '/opt/homebrew/bin/python3' if Path('/opt/homebrew/bin/python3').exists() else sys.executable
OTLP_PORT = 4318
CODEX_CONFIG = Path.home() / '.codex/config.toml'
CODEX_MARK = '# ai-usage dashboard (~/Developer/ai-usage): report each Codex model request to the local collector.'

# LaunchAgent label -> job name carried in OTEL_RESOURCE_ATTRIBUTES (mapped to a display name by the job
# rules). Set "launch_agents" in local.json; see local.example.json.
JOBS = local.settings().get('launch_agents', {})


def telemetry_env(job):
    return {
        'CLAUDE_CODE_ENABLE_TELEMETRY': '1',
        'OTEL_LOGS_EXPORTER': 'otlp',
        'OTEL_METRICS_EXPORTER': 'none',
        'OTEL_EXPORTER_OTLP_PROTOCOL': 'http/json',
        'OTEL_EXPORTER_OTLP_ENDPOINT': f'http://127.0.0.1:{OTLP_PORT}',
        'OTEL_LOGS_EXPORT_INTERVAL': '2000',
        'OTEL_RESOURCE_ATTRIBUTES': f'ai_usage.job={job}',
    }


def uid_domain():
    return f'gui/{os.getuid()}'


def launchctl(*args, check=False):
    return subprocess.run(['launchctl', *args], capture_output=True, text=True, check=check)


def running_pid(label):
    out = launchctl('print', f'{uid_domain()}/{label}').stdout
    match = re.search(r'^\s*pid = (\d+)', out, re.M)
    return int(match.group(1)) if match else None


def backup(path):
    BACKUPS.mkdir(parents=True, exist_ok=True)
    target = BACKUPS / f'{path.name}.{time.strftime("%Y%m%d-%H%M%S")}'
    shutil.copy2(path, target)
    return target


def reload(label, plist):
    launchctl('bootout', f'{uid_domain()}/{label}')
    time.sleep(1)
    result = launchctl('bootstrap', uid_domain(), str(plist))
    if result.returncode:
        raise SystemExit(f'bootstrap {label} failed: {result.stderr.strip()}')


def install_dashboard(claude_probe=True):
    if not Path(PYTHON).exists():
        raise SystemExit(f'{PYTHON} not found')
    config = {
        'Label': LABEL,
        'ProgramArguments': [PYTHON, '-m', 'ai_usage.server', '--host', '0.0.0.0', '--port', '8796',
                             '--otlp-port', str(OTLP_PORT)] + ([] if claude_probe else ['--probe-interval', '0']),
        'WorkingDirectory': str(ROOT),
        'EnvironmentVariables': {
            'PATH': f'{Path.home()}/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin',
            'PYTHONUNBUFFERED': '1',
        },
        'RunAtLoad': True,
        'KeepAlive': True,
        'ThrottleInterval': 10,
        # Standard, not Background: under heavy load macOS starved a Background agent until the page stopped updating.
        'ProcessType': 'Standard',
        'StandardOutPath': str(LOG),
        'StandardErrorPath': str(LOG),
    }
    AGENTS.mkdir(parents=True, exist_ok=True)
    if PLIST.exists():
        backup(PLIST)
    with open(PLIST, 'wb') as handle:
        plistlib.dump(config, handle)
    reload(LABEL, PLIST)
    print(f'Installed {LABEL}: http://{local.hostname()}.local:8796 (log {LOG})')


def wire_jobs(restart_running, remove=False):
    if not JOBS:
        print('No jobs to wire: add "launch_agents" to local.json (see local.example.json).')
    for label, job in JOBS.items():
        plist = AGENTS / f'{label}.plist'
        if not plist.exists():
            print(f'skip {label}: no plist')
            continue
        with open(plist, 'rb') as handle:
            config = plistlib.load(handle)
        env = dict(config.get('EnvironmentVariables') or {})
        wanted = telemetry_env(job)
        if remove:
            changed = any(k in env for k in wanted)
            for key in wanted:
                env.pop(key, None)
        else:
            changed = any(env.get(k) != v for k, v in wanted.items())
            env.update(wanted)
        if not changed:
            print(f'ok   {label}: already {"unwired" if remove else "wired"}')
            continue
        saved = backup(plist)
        if env:
            config['EnvironmentVariables'] = env
        else:
            config.pop('EnvironmentVariables', None)
        with open(plist, 'wb') as handle:
            plistlib.dump(config, handle)
        pid = running_pid(label)
        if pid and not restart_running:
            print(f'edit {label}: running (pid {pid}); takes effect at its next load. Rerun with --restart-running '
                  f'to restart it now. Backup: {saved}')
            continue
        reload(label, plist)
        print(f'done {label}: {"telemetry removed" if remove else "telemetry on as " + job}'
              f'{" (restarted)" if pid else ""}. Backup: {saved}')


def wire_codex(remove=False):
    text = CODEX_CONFIG.read_text() if CODEX_CONFIG.exists() else ''
    block = (f'\n{CODEX_MARK}\n[otel]\n'
             f'exporter = {{ otlp-http = {{ endpoint = "http://127.0.0.1:{OTLP_PORT}/v1/logs", protocol = "json" }} }}\n')
    if remove:
        if CODEX_MARK not in text:
            print('ok   codex: no [otel] block from ai-usage')
            return
        backup(CODEX_CONFIG)
        CODEX_CONFIG.write_text(text.replace(block, '').replace(block.lstrip('\n'), ''))
        print('done codex: [otel] block removed')
        return
    if CODEX_MARK in text:
        print('ok   codex: [otel] already set by ai-usage')
        return
    if re.search(r'^\[otel\]', text, re.M):
        raise SystemExit('~/.codex/config.toml already has an [otel] table; merge the exporter by hand.')
    saved = backup(CODEX_CONFIG) if CODEX_CONFIG.exists() else None
    CODEX_CONFIG.write_text(text.rstrip('\n') + '\n' + block)
    print(f'done codex: [otel] exporter added. Backup: {saved}')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--wire-jobs', action='store_true')
    parser.add_argument('--codex', action='store_true')
    parser.add_argument('--unwire', action='store_true')
    parser.add_argument('--restart-running', action='store_true')
    parser.add_argument('--skip-dashboard', action='store_true')
    parser.add_argument('--no-claude-probe', action='store_true', help='do not spend a Haiku request every 20 minutes to read Claude limits')
    args = parser.parse_args()
    if sys.platform != 'darwin':
        raise SystemExit('macOS only')
    if args.unwire:
        wire_jobs(args.restart_running, remove=True)
        wire_codex(remove=True)
        return
    if not args.skip_dashboard:
        install_dashboard(claude_probe=not args.no_claude_probe)
    if args.wire_jobs:
        wire_jobs(args.restart_running)
    if args.codex:
        wire_codex()


if __name__ == '__main__':
    main()
