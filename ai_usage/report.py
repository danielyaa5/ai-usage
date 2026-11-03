"""Aggregate stored events into the dashboard's JSON."""
import json
import time
from datetime import datetime, timedelta

from . import local, pricing
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
    # Quoted list prices for the models featured in pricing.json, with what each effort cost per request here.
    used = {m['model']: m for m in models_out}
    price_table = []
    for name in pricing.table().get('featured', []):
        efforts = {e['effort']: {'requests': e['requests'], 'per_request': round(e['cost'] / e['requests'], 4)}
                   for e in (used.get(name) or {}).get('efforts', []) if e['requests']}
        vendor = 'anthropic' if name.startswith('claude') else 'openai' if name.startswith('gpt') else 'google'
        price_table.append(dict(model=name, vendor=vendor, price=pricing.price_for(name), efforts=efforts))

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
    agy_monthly = get_kv(db, 'antigravity_monthly_usd')
    plan_info = []
    for name, info in table.get('plans', {}).items():
        used = plans.get(name, empty())
        monthly = info.get('monthly_usd')
        if info.get('vendor') == 'google' and agy_monthly and monthly in (None, 19.99, 99.99, 199.99):
            monthly = agy_monthly
        plan_info.append(dict(plan=name, label=info.get('label'), vendor=info.get('vendor'), monthly_usd=monthly, note=info.get('note'),
                              prorated_usd=round(monthly * days / 30.4, 2) if monthly else None, **finish(dict(used))))

    return dict(
        generated_at=int(now), host=local.display_name(), range=range_name, bucket=bucket_size,
        buckets=keys, series=series_out, series_order=order, totals=finish(total), plans=plan_info, jobs=jobs_out, models=models_out, efforts=efforts_out, price_table=price_table,
        recent=recent, limits=limits(db), sources=sources,
        status=dict(last_scan=get_kv(db, 'last_scan'), scan_result=get_kv(db, 'scan_result'),
                    probe_last=get_kv(db, 'probe_last'), probe_error=get_kv(db, 'probe_error'),
                    telemetry_last=get_kv(db, 'telemetry_last'), telemetry_count=get_kv(db, 'telemetry_count', 0),
                    antigravity_tier=get_kv(db, 'antigravity_tier'),
                    antigravity_quota_last=get_kv(db, 'antigravity_quota_last'),
                    antigravity_quota_error=get_kv(db, 'antigravity_quota_error'),
                    codex_limits_error=get_kv(db, 'codex_limits_error')),
        pricing=dict(checked=table.get('checked'), sources=table.get('sources'), urls=table.get('source_urls', {})))


SHORT_NAMES = {'anthropic': 'Claude', 'openai': 'ChatGPT', 'google': 'Antigravity'}
RANGE_LABELS = {'today': 'Today', '7d': 'Last 7 days', '30d': 'Last 30 days', 'all': 'All recorded'}


def short_group(name):
    """'Gemini Models' -> 'Gemini', 'Claude and GPT models' -> 'Claude and GPT'."""
    if not name:
        return None
    words = name.split()
    return ' '.join(words[:-1]) if len(words) > 1 and words[-1].lower() == 'models' else name


def left_level(left):
    """The dashboard's thresholds: almost out at 10% left or less, running low at 30% or less."""
    return 'critical' if left <= 10 else 'warning' if left <= 30 else 'good'


def widget(db, range_name='7d', now=None):
    """A small, display-ready version of the summary for the macOS widgets: each plan with its limit
    windows and any reader error, and the period's totals. No job names beyond the costliest background job."""
    data = summary(db, range_name, now)
    status = data['status']
    errors = {'anthropic': status.get('probe_error') and f"Probe: {status['probe_error']}",
              'openai': status.get('codex_limits_error'), 'google': status.get('antigravity_quota_error')}
    plans = []
    for plan in data['plans']:
        vendor = plan['vendor']
        limits_here = [l for l in data['limits'] if l['vendor'] == vendor]
        windows = []
        for l in limits_here:
            left = max(0.0, min(100.0, 100.0 - (l['used_pct'] or 0)))
            windows.append(dict(label=l['label'], group=l['group'], group_short=short_group(l['group']),
                                left_pct=round(left, 1), level=left_level(left),
                                resets_at=l['resets_at'], observed_at=l['observed_at']))
        notes = []
        overage = (limits_here[0]['extra'] or {}).get('overageStatus') if vendor == 'anthropic' and limits_here else None
        if overage:
            in_use = ' (in use)' if (limits_here[0]['extra'] or {}).get('isUsingOverage') else ''
            notes.append(f"Extra usage: {'off' if overage == 'rejected' else overage}{in_use}")
        if plan['label']:
            title = plan['label']
        elif vendor == 'google' and status.get('antigravity_tier'):
            title = f"{status['antigravity_tier']} (Antigravity)"
        else:
            title = plan['plan']
        plans.append(dict(plan=plan['plan'], title=title, short=SHORT_NAMES.get(vendor, plan['plan']), vendor=vendor,
                          monthly_usd=plan['monthly_usd'], cost=plan['cost'], prorated_usd=plan['prorated_usd'],
                          requests=plan['requests'], tokens=plan['tokens'], windows=windows, notes=notes,
                          warning=errors.get(vendor) or None))
    totals = data['totals']
    automated = [j for j in data['jobs'] if j['automated']]
    top = automated[0] if automated else None
    return dict(
        generated_at=data['generated_at'], host=data['host'], range=data['range'],
        range_label=RANGE_LABELS[data['range']], last_scan=status.get('last_scan'), plans=plans,
        totals=dict(cost=totals['cost'], requests=totals['requests'], tokens=totals['tokens'], output=totals['output'],
                    unpriced=totals['unpriced'],
                    cache_share=round(totals['cache_read'] / totals['tokens'] * 100) if totals['tokens'] else 0,
                    background_cost=round(sum(j['cost'] for j in automated), 4),
                    top_background_job=dict(job=top['job'], cost=top['cost']) if top else None))
