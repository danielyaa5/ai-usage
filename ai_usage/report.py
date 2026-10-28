"""Aggregate stored events into the dashboard's JSON."""
import json
import time
from datetime import datetime, timedelta

from . import pricing
from .store import get_kv

RANGES = {'today': None, '7d': 7, '30d': 30, 'all': None}
TOKEN_FIELDS = ('input', 'cache_read', 'cache_write', 'output', 'reasoning')
WINDOW_LABELS = {'five_hour': '5-hour', 'seven_day': 'Weekly', 'seven_day_opus': 'Weekly (Opus)',
                 'seven_day_sonnet': 'Weekly (Sonnet)', 'seven_day_fable': 'Weekly (Fable)'}


def window(range_name, now=None):
    """(start ts, bucket size 'hour'|'day', bucket start datetimes) for a range in local time."""
    now = datetime.fromtimestamp(now or time.time())
    midnight = now.replace(hour=0, minute=0, second=0, microsecond=0)
    if range_name == 'today':
        return midnight.timestamp(), 'hour', [midnight + timedelta(hours=h) for h in range(24)]
    days = RANGES.get(range_name)
    if days:
        first = midnight - timedelta(days=days - 1)
        return first.timestamp(), 'day', [first + timedelta(days=d) for d in range(days)]
    return 0, 'day', None


def empty():
    return dict(requests=0, cost=0.0, unpriced=0, **{f: 0 for f in TOKEN_FIELDS})


def add(bucket, row):
    bucket['requests'] += 1
    for field in TOKEN_FIELDS:
        bucket[field] += row[field] or 0
    if row['cost_usd'] is None:
        bucket['unpriced'] += 1
    else:
        bucket['cost'] += row['cost_usd']


def finish(bucket):
    bucket['tokens'] = bucket['input'] + bucket['cache_read'] + bucket['cache_write'] + bucket['output']
    bucket['cost'] = round(bucket['cost'], 4)
    return bucket


def limit_label(vendor, name, extra):
    if vendor == 'openai':
        minutes = (extra or {}).get('window_minutes')
        if minutes == 300:
            return '5-hour'
        if minutes == 10080:
            return 'Weekly'
        return f'{round(minutes / 60)}-hour' if minutes else name.replace('codex_', '').title()
    if vendor == 'google':
        window = (extra or {}).get('window')
        return {'5h': '5-hour', 'weekly': 'Weekly'}.get(window, str(window or name).title())
    return WINDOW_LABELS.get(name, name.replace('_', ' ').title())


def limits(db):
    out = []
    for row in db.execute('SELECT * FROM limits ORDER BY vendor, window'):
        extra = json.loads(row['extra'] or '{}')
        out.append(dict(vendor=row['vendor'], window=row['window'], label=limit_label(row['vendor'], row['window'], extra),
                        group=extra.get('group'), used_pct=row['used_pct'], resets_at=row['resets_at'],
                        observed_at=row['observed_at'], plan=row['plan'], extra=extra))
    # Shortest window first within each group, groups in the order the tool lists them.
    span = {'5-hour': 0, 'Weekly': 1}
    out.sort(key=lambda l: (l['vendor'], l['extra'].get('order', 0), span.get(l['label'], 2), l['label']))
    return out


def summary(db, range_name='7d', now=None):
    if range_name not in RANGES:
        range_name = '7d'
    now = now or time.time()
    start, bucket_size, buckets = window(range_name, now)
    rows = db.execute('SELECT * FROM events WHERE ts>=? ORDER BY ts', (int(start),)).fetchall()
    if buckets is None:  # all time: one bucket per day from the first event
        first = datetime.fromtimestamp(rows[0]['ts'] if rows else now).replace(hour=0, minute=0, second=0, microsecond=0)
        days = (datetime.fromtimestamp(now) - first).days + 1
        buckets = [first + timedelta(days=d) for d in range(days)]
    keys = [b.strftime('%Y-%m-%d %H' if bucket_size == 'hour' else '%Y-%m-%d') for b in buckets]
    index = {k: i for i, k in enumerate(keys)}

    total, plans, by_job, by_model, by_effort = empty(), {}, {}, {}, {}
    series = {'plan': {}, 'model': {}, 'effort': {}}
    for row in rows:
        add(total, row)
        add(plans.setdefault(row['plan'], empty()), row)
        job = by_job.setdefault(row['job'], dict(empty(), tools=set(), models={}, details={}, last=0))
        add(job, row)
        job['tools'].add(row['tool'])
        effort = row['effort'] or 'unknown'
        add(job['models'].setdefault((row['model'], effort), empty()), row)
        add(by_effort.setdefault(effort, empty()), row)
        if row['detail']:
            job['details'][row['detail']] = job['details'].get(row['detail'], 0) + (row['cost_usd'] or 0)
        job['last'] = max(job['last'], row['ts'])
        model = by_model.setdefault(row['model'], dict(empty(), vendor=row['vendor'], plans=set(), efforts={}))
        add(model['efforts'].setdefault(effort, empty()), row)
        model['plans'].add(row['plan'])
        add(model, row)
        key = datetime.fromtimestamp(row['ts']).strftime('%Y-%m-%d %H' if bucket_size == 'hour' else '%Y-%m-%d')
        if key in index:
            for group, name in (('plan', row['plan']), ('model', row['model']), ('effort', effort)):
                point = series[group].setdefault(name, [None] * len(keys))
                if point[index[key]] is None:
                    point[index[key]] = empty()
                add(point[index[key]], row)

    jobs_out = []
    for name, job in by_job.items():
        details = sorted(job.pop('details').items(), key=lambda kv: -kv[1])[:5]
        jobs_out.append(dict(finish(job), job=name, tools=sorted(job['tools']),
                             models=sorted(({'model': m, 'effort': e, **finish(v)} for (m, e), v in job['models'].items()),
                                           key=lambda m: -m['cost']),
                             details=[d for d, _ in details],
                             automated=not name.endswith('(interactive)')))
    jobs_out.sort(key=lambda j: -j['cost'])
    rank = {e: i for i, e in enumerate(pricing.EFFORTS + ('unknown',))}
    models_out = sorted((dict(finish(v), model=m, plans=sorted(v['plans']), priced=pricing.price_for(m) is not None,
                              price=pricing.price_for(m),
                              efforts=sorted(({'effort': e, **finish(s)} for e, s in v['efforts'].items()),
                                             key=lambda x: rank.get(x['effort'], 99)))
                         for m, v in by_model.items()), key=lambda m: -m['cost'])
    efforts_out = sorted(({'effort': e, **finish(s)} for e, s in by_effort.items()), key=lambda x: rank.get(x['effort'], 99))
    # The daily chart shows the 7 costliest models by name and folds the rest into one series.
    top = [m['model'] for m in models_out[:7]]
    rest = [m['model'] for m in models_out[7:]]
    if rest:
        merged = [None] * len(keys)
        for name in rest:
            for i, point in enumerate(series['model'].pop(name, [])):
                if point:
                    merged[i] = merged[i] or empty()
                    for field in ('requests', 'cost', 'unpriced') + TOKEN_FIELDS:
                        merged[i][field] += point[field]
        series['model']['Other models'] = merged
    order = {'plan': list(series['plan']), 'model': top + (['Other models'] if rest else []),
             'effort': [e['effort'] for e in efforts_out]}
    series_out = {group: {name: [finish(p) if p else None for p in points] for name, points in named.items()}
                  for group, named in series.items()}

    recent = [dict(ts=r['ts'], job=r['job'], detail=r['detail'], tool=r['tool'], model=r['model'], plan=r['plan'],
                   tokens=r['input'] + r['cache_read'] + r['cache_write'] + r['output'], output=r['output'],
                   cost=r['cost_usd'], source=r['source'])
              for r in db.execute('SELECT * FROM events ORDER BY ts DESC LIMIT 40')]
    sources = [dict(source=r['source'], requests=r['n'], first=r['first'], last=r['last'])
               for r in db.execute('SELECT source, COUNT(*) n, MIN(ts) first, MAX(ts) last FROM events GROUP BY source')]

    table = pricing.table()
    days = max((now - start) / 86400, 1 / 24) if start else max(len(keys), 1)
    plan_info = []
    for name, info in table.get('plans', {}).items():
        used = plans.get(name, empty())
        monthly = info.get('monthly_usd')
        plan_info.append(dict(plan=name, vendor=info.get('vendor'), monthly_usd=monthly, note=info.get('note'),
                              prorated_usd=round(monthly * days / 30.4, 2) if monthly else None, **finish(dict(used))))

    return dict(
        generated_at=int(now), host='my-mac', range=range_name, bucket=bucket_size,
        buckets=keys, series=series_out, series_order=order, totals=finish(total), plans=plan_info, jobs=jobs_out, models=models_out, efforts=efforts_out,
        recent=recent, limits=limits(db), sources=sources,
        status=dict(last_scan=get_kv(db, 'last_scan'), scan_result=get_kv(db, 'scan_result'),
                    probe_last=get_kv(db, 'probe_last'), probe_error=get_kv(db, 'probe_error'),
                    telemetry_last=get_kv(db, 'telemetry_last'), telemetry_count=get_kv(db, 'telemetry_count', 0),
                    antigravity_tier=get_kv(db, 'antigravity_tier'),
                    antigravity_quota_last=get_kv(db, 'antigravity_quota_last'),
                    antigravity_quota_error=get_kv(db, 'antigravity_quota_error'),
                    codex_limits_error=get_kv(db, 'codex_limits_error')),
        pricing=dict(checked=table.get('checked'), sources=table.get('sources')))
