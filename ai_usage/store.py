"""SQLite store for usage events, scan progress and plan-limit snapshots."""
import json
import os
import sqlite3
import threading
import time
from pathlib import Path

DATA_DIR = Path(os.environ.get('AI_USAGE_DATA', Path.home() / 'Library/Application Support/ai-usage'))

SCHEMA = '''
CREATE TABLE IF NOT EXISTS events (
    id TEXT PRIMARY KEY,          -- unique per model request, shared across sources that see the same request
    ts INTEGER NOT NULL,          -- unix seconds
    source TEXT NOT NULL,         -- claude_transcript, codex_rollout, antigravity_cli, antigravity_ide, otel_claude, otel_codex
    vendor TEXT NOT NULL,         -- anthropic, openai, google
    plan TEXT NOT NULL,           -- which subscription or key paid for it
    tool TEXT NOT NULL,           -- Claude Code, Codex, Antigravity CLI, Antigravity IDE
    model TEXT NOT NULL,
    job TEXT NOT NULL,
    detail TEXT,                  -- session title, task name or project folder
    session TEXT,
    cwd TEXT,
    input INTEGER NOT NULL DEFAULT 0,        -- uncached input
    cache_read INTEGER NOT NULL DEFAULT 0,
    cache_write INTEGER NOT NULL DEFAULT 0,
    output INTEGER NOT NULL DEFAULT 0,       -- includes reasoning
    reasoning INTEGER NOT NULL DEFAULT 0,
    cost_usd REAL,                -- API-list equivalent, reported by the tool or priced here
    cost_basis TEXT,              -- reported, priced, unpriced
    speed TEXT
);
CREATE INDEX IF NOT EXISTS events_ts ON events(ts);
CREATE INDEX IF NOT EXISTS events_session ON events(source, session);
CREATE TABLE IF NOT EXISTS files (
    path TEXT PRIMARY KEY,
    size INTEGER,
    mtime REAL,
    offset INTEGER,
    state TEXT                    -- per-file parser state (JSON)
);
CREATE TABLE IF NOT EXISTS limits (
    vendor TEXT NOT NULL,
    window TEXT NOT NULL,         -- five_hour, seven_day, codex_primary, ...
    used_pct REAL,
    resets_at INTEGER,
    observed_at INTEGER NOT NULL,
    plan TEXT,
    extra TEXT,
    PRIMARY KEY (vendor, window)
);
CREATE TABLE IF NOT EXISTS limit_history (
    vendor TEXT NOT NULL,
    window TEXT NOT NULL,
    used_pct REAL,
    observed_at INTEGER NOT NULL,
    PRIMARY KEY (vendor, window, observed_at)
);
CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT);
'''

EVENT_COLUMNS = ('id', 'ts', 'source', 'vendor', 'plan', 'tool', 'model', 'job', 'detail', 'session', 'cwd',
                 'input', 'cache_read', 'cache_write', 'output', 'reasoning', 'cost_usd', 'cost_basis', 'speed')

_lock = threading.RLock()


def connect(path=None, init=True):
    """Open the store. Each thread uses its own connection; WAL lets readers and the writer overlap."""
    path = Path(path or DATA_DIR / 'usage.sqlite')
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    db = sqlite3.connect(path, timeout=30)
    db.row_factory = sqlite3.Row
    if init:
        db.execute('PRAGMA journal_mode=WAL')
        db.executescript(SCHEMA)
    return db


def put_events(db, events, prefer_new=False):
    """Insert events. When an id already exists, the row with more output tokens wins (Claude Code writes a
    message once per content block, and later copies carry the final count). With prefer_new, a duplicate
    from another source only fills in a job or detail the stored row lacks."""
    if not events:
        return 0
    tokens = ('input', 'cache_read', 'cache_write', 'output', 'reasoning')
    rows = [tuple((e.get(c) or 0) if c in tokens else e.get(c) for c in EVENT_COLUMNS) for e in events]
    placeholders = ','.join('?' * len(EVENT_COLUMNS))
    updates = ','.join(f'{c}=excluded.{c}' for c in EVENT_COLUMNS if c != 'id')
    with _lock:
        before = db.total_changes
        db.executemany(
            f'INSERT INTO events ({",".join(EVENT_COLUMNS)}) VALUES ({placeholders}) '
            f'ON CONFLICT(id) DO UPDATE SET {updates} WHERE excluded.output > events.output '
            f'AND excluded.source = events.source', rows)
        # Same request seen by another source (transcript and telemetry): keep the stored numbers and take
        # whichever attribution is more specific.
        db.executemany(
            'UPDATE events SET job=?, detail=COALESCE(detail, ?) WHERE id=? AND source<>? AND job LIKE ?',
            [(e['job'], e.get('detail'), e['id'], e['source'], '% (interactive)') for e in events
             if not e['job'].endswith('(interactive)')])
        db.commit()
        return db.total_changes - before


def file_state(db, path):
    row = db.execute('SELECT size, mtime, offset, state FROM files WHERE path=?', (str(path),)).fetchone()
    if not row:
        return None
    return {'size': row['size'], 'mtime': row['mtime'], 'offset': row['offset'],
            'state': json.loads(row['state'] or '{}')}


def save_file_state(db, path, size, mtime, offset, state):
    with _lock:
        db.execute('INSERT OR REPLACE INTO files VALUES (?,?,?,?,?)',
                   (str(path), size, mtime, offset, json.dumps(state, separators=(',', ':'))))
        db.commit()


def put_limit(db, vendor, window, used_pct, resets_at, plan=None, extra=None, observed_at=None):
    observed_at = int(observed_at or time.time())
    with _lock:
        current = db.execute('SELECT observed_at FROM limits WHERE vendor=? AND window=?', (vendor, window)).fetchone()
        if current and current['observed_at'] > observed_at:
            return
        db.execute('INSERT OR REPLACE INTO limits VALUES (?,?,?,?,?,?,?)',
                   (vendor, window, used_pct, resets_at, observed_at, plan, json.dumps(extra or {})))
        # Keep history sparse: a point when the value moves or every 30 minutes.
        last = db.execute('SELECT used_pct, observed_at FROM limit_history WHERE vendor=? AND window=? '
                          'ORDER BY observed_at DESC LIMIT 1', (vendor, window)).fetchone()
        if not last or last['used_pct'] != used_pct or observed_at - last['observed_at'] >= 1800:
            db.execute('INSERT OR IGNORE INTO limit_history VALUES (?,?,?,?)', (vendor, window, used_pct, observed_at))
        db.commit()


def get_kv(db, key, default=None):
    row = db.execute('SELECT value FROM kv WHERE key=?', (key,)).fetchone()
    return json.loads(row['value']) if row else default


def set_kv(db, key, value):
    with _lock:
        db.execute('INSERT OR REPLACE INTO kv VALUES (?,?)', (key, json.dumps(value)))
        db.commit()
