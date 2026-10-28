"""Readers for the usage records Claude Code, Codex and Antigravity leave on disk.

Each scanner is incremental: JSONL files are read from the byte offset where the last scan stopped,
and Antigravity's SQLite conversations are re-read only when their modification time changes.
Nothing here writes to the tools' own files.
"""
import glob
import json
import os
import re
import sqlite3
from datetime import datetime
from pathlib import Path

from . import jobs, pricing, protowire as pw
from .store import file_state, get_kv, put_events, put_limit, save_file_state, set_kv

HOME = Path.home()
CLAUDE_PROJECTS = HOME / '.claude/projects'
CLAUDE_DESKTOP_SESSIONS = HOME / 'Library/Application Support/Claude/claude-code-sessions'
CODEX_HOME = HOME / '.codex'
ANTIGRAVITY = {
    'antigravity_cli': (HOME / '.gemini/antigravity-cli', 'Antigravity CLI'),
    'antigravity_ide': (HOME / '.gemini/antigravity', 'Antigravity IDE'),
}
CLAUDE_PLAN, OPENAI_PLAN, GOOGLE_PLAN = 'Claude Max 20x', 'ChatGPT Pro', 'Google (Antigravity)'
MAX_LINE = 4_000_000


def iso_ts(value):
    try:
        return int(datetime.fromisoformat(str(value).replace('Z', '+00:00')).timestamp())
    except (TypeError, ValueError):
        return None


def read_new_lines(db, path):
    """Yield parsed JSON objects appended to path since the last scan, then remember the new offset.
    A file that shrank (rewritten) is read again from the start; duplicates are absorbed by event ids."""
    try:
        stat = os.stat(path)
    except FileNotFoundError:
        return [], {}
    prev = file_state(db, path)
    if prev and prev['size'] == stat.st_size and prev['mtime'] == stat.st_mtime:
        return [], prev['state']
    offset = prev['offset'] if prev and stat.st_size >= prev['offset'] else 0
    state = prev['state'] if prev and offset else {}
    items = []
    with open(path, 'rb') as handle:
        handle.seek(offset)
        data = handle.read()
    end = data.rfind(b'\n') + 1  # leave a half-written last line for next time
    for raw in data[:end].splitlines():
        if not raw.strip() or len(raw) > MAX_LINE:
            continue
        try:
            items.append(json.loads(raw))
        except ValueError:
            continue
    state['_pending'] = (stat.st_size, stat.st_mtime, offset + end)
    return items, state


def commit_file(db, path, state):
    size, mtime, offset = state.pop('_pending')
    save_file_state(db, path, size, mtime, offset, state)


# --- Claude Code -------------------------------------------------------------------------------------

def claude_desktop_sessions():
    """cliSessionId -> {title, task} from the Claude desktop app's session records."""
    found = {}
    for path in glob.glob(str(CLAUDE_DESKTOP_SESSIONS / '*/*/*.json')):
        try:
            record = json.loads(Path(path).read_text())
        except (OSError, ValueError):
            continue
        if record.get('cliSessionId'):
            found[record['cliSessionId']] = {'title': record.get('title'), 'task': record.get('scheduledTaskId')}
    return found


def first_text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        for block in content:
            if isinstance(block, dict) and block.get('type') == 'text' and block.get('text'):
                return block['text']
    return ''


def claude_event(line, desktop, state):
    message = line.get('message') or {}
    usage = message.get('usage') or {}
    model = message.get('model') or ''
    if not usage or not model or model.startswith('<'):
        return None
    session = line.get('sessionId')
    cache_write = int(usage.get('cache_creation_input_tokens') or 0)
    cache_1h = int((usage.get('cache_creation') or {}).get('ephemeral_1h_input_tokens') or 0)
    tokens = {
        'input': int(usage.get('input_tokens') or 0),
        'cache_read': int(usage.get('cache_read_input_tokens') or 0),
        'cache_write': cache_write,
        'output': int(usage.get('output_tokens') or 0),
        'reasoning': int((usage.get('output_tokens_details') or {}).get('thinking_tokens') or 0),
    }
    if not any(tokens.values()):
        return None
    speed = usage.get('speed')
    info = desktop.get(session) or {}
    cwd = line.get('cwd')
    if info.get('task'):
        job, detail = jobs.scheduled(info['task']), info.get('title')
    else:
        matched = jobs.from_prompt(state.get('prompts', {}).get(session))
        if not matched and str(line.get('entrypoint', '')).startswith('sdk'):
            matched = jobs.from_cwd(cwd) or ('Claude Code (scripts)', None)
        job, detail = matched or ('Claude Code (interactive)', None)
        detail = detail or info.get('title') or jobs.folder(cwd)
    cost = pricing.cost(model, tokens['input'], tokens['cache_read'], cache_write, tokens['output'], cache_1h, speed)
    return dict(
        id='anthropic:' + (line.get('requestId') or message.get('id') or line.get('uuid')),
        ts=iso_ts(line.get('timestamp')) or 0, source='claude_transcript', vendor='anthropic', plan=CLAUDE_PLAN,
        tool='Claude Code', model=pricing.normalize_model(model), job=job, detail=detail, session=session, cwd=cwd,
        cost_usd=cost, cost_basis='priced' if cost is not None else 'unpriced', speed=speed,
        effort=pricing.effort_name(line.get('effort')), **tokens)


def scan_claude(db, root=CLAUDE_PROJECTS):
    desktop = claude_desktop_sessions()
    added = 0
    for path in glob.glob(str(Path(root) / '**/*.jsonl'), recursive=True):
        lines, state = read_new_lines(db, path)
        if not lines and '_pending' not in state:
            continue
        prompts = state.setdefault('prompts', {})
        events = []
        for line in lines:
            if not isinstance(line, dict):
                continue
            session = line.get('sessionId')
            if line.get('type') == 'user' and session and session not in prompts and not line.get('isMeta'):
                text = first_text((line.get('message') or {}).get('content'))
                if text and not text.startswith('<'):
                    prompts[session] = text[:400]
            if line.get('type') == 'assistant':
                event = claude_event(line, desktop, state)
                if event:
                    events.append(event)
        added += put_events(db, events)
        commit_file(db, path, state)
    return added


# --- Codex -------------------------------------------------------------------------------------------

def codex_titles():
    titles = {}
    try:
        with open(CODEX_HOME / 'session_index.jsonl') as handle:
            for raw in handle:
                try:
                    item = json.loads(raw)
                except ValueError:
                    continue
                if item.get('id') and item.get('thread_name'):
                    titles[item['id']] = item['thread_name']
    except OSError:
        pass
    return titles


def codex_job(state, titles):
    session = state.get('session')
    interactive = state.get('originator') not in ('codex_exec',) and state.get('source') != 'exec'
    matched = jobs.from_prompt(state.get('prompt'))
    if not matched and not interactive:
        matched = jobs.from_cwd(state.get('cwd')) or ('Codex (scripts)', None)
    job, detail = matched or ('Codex (interactive)', None)
    return job, detail or titles.get(session) or jobs.folder(state.get('cwd'))


def codex_tokens(usage):
    total_input = int(usage.get('input_tokens') or 0)
    cached = int(usage.get('cached_input_tokens') or 0)
    return {
        'input': max(total_input - cached, 0),
        'cache_read': cached,
        'cache_write': int(usage.get('cache_write_input_tokens') or 0),
        'output': int(usage.get('output_tokens') or 0),
        'reasoning': int(usage.get('reasoning_output_tokens') or 0),
    }


def codex_limits(db, limits, observed_at):
    if not isinstance(limits, dict):
        return
    plan = limits.get('plan_type')
    for name in ('primary', 'secondary'):
        window = limits.get(name)
        if isinstance(window, dict) and window.get('used_percent') is not None:
            minutes = window.get('window_minutes')
            put_limit(db, 'openai', f'codex_{name}', float(window['used_percent']), window.get('resets_at'), plan,
                      {'window_minutes': minutes, 'credits': limits.get('credits'),
                       'reached': limits.get('rate_limit_reached_type')}, observed_at)


def scan_codex(db, home=CODEX_HOME):
    titles = codex_titles()
    files = glob.glob(str(Path(home) / 'sessions/**/rollout-*.jsonl'), recursive=True)
    files += glob.glob(str(Path(home) / 'archived_sessions/**/rollout-*.jsonl'), recursive=True)
    added = 0
    for path in files:
        lines, state = read_new_lines(db, path)
        if not lines and '_pending' not in state:
            continue
        turns = state.setdefault('turns', {})
        events, pending = [], []
        for line in lines:
            kind, payload = line.get('type'), line.get('payload') if isinstance(line.get('payload'), dict) else {}
            ts = iso_ts(line.get('timestamp')) or 0
            if kind == 'session_meta':
                state.update(session=payload.get('id') or payload.get('session_id'), cwd=payload.get('cwd'),
                             originator=payload.get('originator'), source=payload.get('source'))
            elif kind == 'turn_context':
                if payload.get('model'):
                    state['model'], state['effort'] = payload['model'], payload.get('effort')
                    if payload.get('turn_id'):
                        turns[payload['turn_id']] = [payload['model'], payload.get('effort')]
                        if len(turns) > 200:
                            turns.pop(next(iter(turns)))
                state['cwd'] = state.get('cwd') or payload.get('cwd')
            elif kind == 'event_msg' and payload.get('type') == 'user_message' and not state.get('prompt'):
                state['prompt'] = str(payload.get('message') or '')[:400]
            elif kind == 'token_usage_record' and isinstance(payload.get('usage'), dict):
                state['records'] = True
                model, effort = turns.get(payload.get('turn_id')) or [state.get('model') or 'unknown', state.get('effort')]
                pending.append((ts, 'openai:' + (payload.get('response_id') or f"{state.get('session')}:{ts}"),
                                model, effort, codex_tokens(payload['usage'])))
            elif kind == 'event_msg' and payload.get('type') == 'token_count':
                codex_limits(db, payload.get('rate_limits'), ts)
                info = payload.get('info') or {}
                if not state.get('records') and isinstance(info.get('last_token_usage'), dict):
                    total = (info.get('total_token_usage') or {}).get('total_tokens')
                    pending.append((ts, f"openai:{state.get('session')}:total:{total}", state.get('model') or 'unknown',
                                    state.get('effort'), codex_tokens(info['last_token_usage'])))
        job, detail = codex_job(state, titles)
        for ts, event_id, model, effort, tokens in pending:
            if not any(tokens.values()):
                continue
            cost = pricing.cost(model, tokens['input'], tokens['cache_read'], tokens['cache_write'], tokens['output'])
            events.append(dict(id=event_id, ts=ts, source='codex_rollout', vendor='openai', plan=OPENAI_PLAN,
                               tool='Codex', model=pricing.normalize_model(model), job=job, detail=detail,
                               session=state.get('session'), cwd=state.get('cwd'), cost_usd=cost,
                               cost_basis='priced' if cost is not None else 'unpriced', speed=None,
                               effort=pricing.effort_name(effort), **tokens))
        added += put_events(db, events)
        commit_file(db, path, state)
    return added


# --- Antigravity -------------------------------------------------------------------------------------

def antigravity_summaries(base):
    """conversation id -> (title, workspace folder) from the IDE's summary index."""
    found = {}
    path = Path(base) / 'conversation_summaries.db'
    if not path.exists():
        return found
    try:
        con = sqlite3.connect(f'file:{path}?mode=ro', uri=True, timeout=5)
        for cid, title, workspaces in con.execute(
                'SELECT conversation_id, title, workspace_uris FROM conversation_summaries'):
            folder = None
            for uri in str(workspaces or '').replace('[', ' ').replace(']', ' ').replace('"', ' ').replace(',', ' ').split():
                if uri.startswith('file://'):
                    folder = uri[len('file://'):]
                    break
            found[cid] = (title or None, folder)
        con.close()
    except sqlite3.Error:
        pass
    return found


def read_antigravity_db(path, model_names, labels=None):
    """Return (first prompt, [usage dicts with ts]) for one conversation database. Fills model_names and
    labels (model enum -> model id, and -> display name such as 'Gemini 3.8 Flash (High)')."""
    labels = {} if labels is None else labels
    con = sqlite3.connect(f'file:{path}?mode=ro', uri=True, timeout=5)
    try:
        for (data,) in con.execute('SELECT data FROM gen_metadata'):
            usage = pw.usage(pw.first(data, 1, 4) or b'')
            name = pw.text(pw.first(data, 1, 19))
            label = pw.text(pw.first(data, 1, 21))
            if usage and name and usage['model_enum'] is not None:
                model_names[str(usage['model_enum'])] = name
            if usage and label and usage['model_enum'] is not None:
                labels[str(usage['model_enum'])] = label
        prompt, rows = None, []
        for idx, step_type, meta, payload in con.execute(
                'SELECT idx, step_type, metadata, step_payload FROM steps ORDER BY idx'):
            if step_type == 14 and prompt is None:
                prompt = pw.text(pw.first(payload, 19, 2)) or ''
            usage = pw.usage(pw.first(meta, 9) or b'')
            if not usage:
                continue
            ts = pw.first(meta, 8, 1) or pw.first(meta, 1, 1)
            usage.update(idx=idx, ts=ts if isinstance(ts, int) else None)
            rows.append(usage)
        return prompt, rows
    finally:
        con.close()


def antigravity_effort(enum, labels, app_labels):
    """Effort for a model enum from its display name, e.g. 'Gemini 4 Argon (Low)' -> 'low'. The app's own
    model list (saved by the quota reader) names models as MODEL_PLACEHOLDER_M<enum - 1000>."""
    label = labels.get(str(enum))
    if not label and isinstance(enum, int):
        label = app_labels.get(f'MODEL_PLACEHOLDER_M{enum - 1000}')
    match = re.search(r'\(([^)]+)\)\s*$', label or '')
    return pricing.effort_name(match.group(1)) if match else None


def scan_antigravity(db, sources=None):
    sources = sources or ANTIGRAVITY
    model_names = get_kv(db, 'antigravity_models', {})
    labels = get_kv(db, 'antigravity_labels', {})
    app_labels = get_kv(db, 'antigravity_model_labels', {})
    added = 0
    for source, (base, tool) in sources.items():
        summaries = antigravity_summaries(base)
        for path in glob.glob(str(Path(base) / 'conversations/*.db')):
            try:
                stat = os.stat(path)
            except FileNotFoundError:
                continue
            prev = file_state(db, path)
            if prev and prev['mtime'] == stat.st_mtime and prev['size'] == stat.st_size:
                continue
            cid = Path(path).stem
            try:
                prompt, rows = read_antigravity_db(path, model_names, labels)
            except sqlite3.Error:
                continue  # busy or mid-write; retried on the next scan
            title, workspace = summaries.get(cid, (None, None))
            matched = jobs.from_prompt(prompt)
            if not matched:
                matched = ('Antigravity (interactive)', None) if source == 'antigravity_ide' else ('Antigravity CLI (other)', None)
            job, detail = matched
            detail = detail or title or jobs.folder(workspace)
            events = []
            for row in rows:
                model = model_names.get(str(row['model_enum']), f"antigravity-model-{row['model_enum']}")
                model, effort = pricing.split_effort(model)
                effort = antigravity_effort(row['model_enum'], labels, app_labels) or effort
                cost = pricing.cost(model, row['input'], row['cache_read'], row['cache_write'], row['output'])
                events.append(dict(
                    id='google:' + (row['response_id'] or f'{cid}:{row["idx"]}'), ts=row['ts'] or int(stat.st_mtime),
                    source=source, vendor='anthropic' if model.startswith('claude') else 'google', plan=GOOGLE_PLAN,
                    tool=tool, model=pricing.normalize_model(model), job=job, detail=detail, session=cid,
                    cwd=workspace, input=row['input'], cache_read=row['cache_read'], cache_write=row['cache_write'],
                    output=row['output'], reasoning=row['reasoning'], cost_usd=cost,
                    cost_basis='priced' if cost is not None else 'unpriced', speed=None, effort=effort))
            added += put_events(db, events)
            save_file_state(db, path, stat.st_size, stat.st_mtime, 0, {})
    set_kv(db, 'antigravity_models', model_names)
    set_kv(db, 'antigravity_labels', labels)
    return added


def dedupe(db):
    """Codex telemetry also arrives for sessions Codex logs to disk; the log copy wins."""
    db.execute("DELETE FROM events WHERE source='otel_codex' AND session IN "
               "(SELECT DISTINCT session FROM events WHERE source='codex_rollout')")
    db.commit()


SCAN_VERSION = 3  # bump when parsing changes so stored events are read again (2: effort, 3: model names)


def reattribute(db):
    """When the job rules or the parsers change, read every log again so stored events pick up the new rules.
    Events whose logs are gone keep what they had."""
    path = jobs.jobs_path()
    mtime = f'{path.name}:{os.path.getmtime(path)}'
    # The Antigravity app's model list (saved by the quota reader) names the effort of model ids that
    # the conversation files leave unlabeled, so a change to it is a reason to read them again too.
    labels = len(get_kv(db, 'antigravity_model_labels', {}) or {})
    if (get_kv(db, 'jobs_mtime') != mtime or get_kv(db, 'scan_version') != SCAN_VERSION
            or get_kv(db, 'labels_seen', 0) != labels):
        db.execute('DELETE FROM files')
        db.commit()
        set_kv(db, 'jobs_mtime', mtime)
        set_kv(db, 'scan_version', SCAN_VERSION)
        set_kv(db, 'labels_seen', labels)
        split_stored_models(db)


def split_stored_models(db):
    """Antigravity CLI conversations are pruned, so events whose files are gone cannot be read again.
    Move an effort suffix in their stored model name ('claude-opus-5-5-high') into the effort column."""
    for (model,) in db.execute('SELECT DISTINCT model FROM events').fetchall():
        base, effort = pricing.split_effort(model)
        if effort:
            db.execute('UPDATE events SET model=?, effort=COALESCE(effort, ?) WHERE model=?', (base, effort, model))
    db.commit()


def scan_all(db):
    reattribute(db)
    counts = {}
    for name, scanner in (('claude', scan_claude), ('codex', scan_codex), ('antigravity', scan_antigravity)):
        try:
            counts[name] = scanner(db)
        except Exception as error:  # one broken source must not stop the others
            counts[name] = f'error: {error}'
    dedupe(db)
    return counts
